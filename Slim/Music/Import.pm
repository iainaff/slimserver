package Slim::Music::Import;

# SlimServer Copyright (c) 2001-2004 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;

use base qw(Class::Data::Inheritable);

use Config;
use FindBin qw($Bin);
use Proc::Background;
use Scalar::Util qw(blessed);

use Slim::Music::Info;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;

{
	my $class = __PACKAGE__;

	for my $accessor (qw(cleanupDatabase scanPlaylistsOnly useFolderImporter scanningProcess)) {

		$class->mk_classdata($accessor);
	}
}

# Total of how many file scanners are running
our %importsRunning = ();
our %Importers      = ();

my $folderScanClass = 'Slim::Music::MusicFolderScan';

sub launchScan {
	my ($class, $args) = @_;

	# Pass along the prefs file - might need to do this for other flags,
	# such as logfile as well.
	if (defined $::prefsfile && -r $::prefsfile) {
		$args->{"prefsfile=$::prefsfile"} = 1;
	}

	# Ugh - need real logging via Log::Log4perl
	# Hardcode the list of debugging options that the scanner accepts.
	my @debug = qw(d_info d_server d_import d_parse d_parse d_sql d_startup d_itunes d_moodlogic d_musicmagic);

	# Search the main namespace hash to see if they're defined.
	for my $opt (@debug) {

		no strict 'refs';
		my $check = '::' . $opt;

		$args->{$opt} = 1 if $$check;
	}

	# Add in the various importer flags
	for my $importer (qw(itunes musicmagic moodlogic)) {

		if (Slim::Utils::Prefs::get($importer)) {

			$args->{$importer} = 1;
		}
	}

	# Set scanner priority.  Use the current server priority unless 
	# scannerPriority has been specified.

	my $scannerPriority = Slim::Utils::Prefs::get("scannerPriority");

	unless (defined $scannerPriority && $scannerPriority ne "") {
		$scannerPriority = Slim::Utils::Misc::getPriority();
	}

	if (defined $scannerPriority && $scannerPriority ne "") {
		$args->{"priority=$scannerPriority"} = 1;
	}

	my @scanArgs = map { "--$_" } keys %{$args};

	my $command  = "$Bin/scanner.pl";

	# Check for different scanner types.
	if (Slim::Utils::OSDetect::OS() eq 'win' && -x "$Bin/scanner.exe") {

		$command  = "$Bin/scanner.exe";

	} elsif (Slim::Utils::OSDetect::isDebian() && -x '/usr/sbin/slimserver-scanner') {

		$command  = '/usr/sbin/slimserver-scanner';
	}

	# Bug: 3530 - use the same version of perl we were started with.
	if ($Config{'perlpath'} && -x $Config{'perlpath'} && $command !~ /\.exe$/) {

		unshift @scanArgs, $command;
		$command  = $Config{'perlpath'};
	}

	$class->scanningProcess(
		Proc::Background->new($command, @scanArgs)
	);

	# Set a timer to check on the scanning process.
	$class->checkScanningStatus;

	return 1;
}

sub checkScanningStatus {
	my $class = shift || __PACKAGE__;

	Slim::Utils::Timers::killTimers(0, \&checkScanningStatus);

	# Run again if we're still scanning.
	if ($class->stillScanning) {

		Slim::Utils::Timers::setTimer(0, (Time::HiRes::time() + 60), \&checkScanningStatus);

	} else {

		Slim::Control::Request::notifyFromArray(undef, [qw(rescan done)]);
	}
}

# Force a rescan of all the importers.
# This is called by the scanner.pl helper program.
sub startScan {
	my $class  = shift;
	my $import = shift;

	# If we are scanning a music folder, do that first - as we'll gather
	# the most information from files that way and subsequent importers
	# need to do less work.
	if ($Importers{$folderScanClass} && !$class->scanPlaylistsOnly) {

		$class->runImporter($folderScanClass, $import);

		$class->useFolderImporter(1);
	}

	# Check Import scanners
	for my $importer (keys %Importers) {

		# Don't rescan the music folder again.
		if ($importer eq $folderScanClass) {
			next;
		}

		# These importers all implement 'playlist only' scanning.
		# See bug: 1892
		if ($class->scanPlaylistsOnly && !$Importers{$importer}->{'playlistOnly'}) {
			next;
		}

		$class->runImporter($importer, $import);
	}

	$class->scanPlaylistsOnly(0);

	# Auto-identify VA/Compilation albums
	$::d_import && msg("Import: Starting mergeVariousArtistsAlbums().\n");

	$importsRunning{'mergeVariousAlbums'} = Time::HiRes::time();

	Slim::Schema->mergeVariousArtistsAlbums;

	# Post-process artwork, so we can use title formats, and use a generic
	# image to speed up artwork loading.
	$::d_import && msg("Import: Starting findArtwork().\n");

	$importsRunning{'findArtwork'} = Time::HiRes::time();

	Slim::Music::Artwork->findArtwork;

	# Remove and dangling references.
	if ($class->cleanupDatabase) {

		# Don't re-enter
		$class->cleanupDatabase(0);

		$importsRunning{'cleanupStaleEntries'} = Time::HiRes::time();

		Slim::Schema->cleanupStaleTrackEntries;
	}

	# Reset
	$class->useFolderImporter(0);

	# Always run an optimization pass at the end of our scan.
	$::d_import && msg("Import: Starting Database optimization.\n");

	$importsRunning{'dbOptimize'} = Time::HiRes::time();

	Slim::Schema->optimizeDB;

	$class->endImporter('dbOptimize');

	$::d_import && msg("Import: Finished background scanning.\n");
}

sub deleteImporter {
	my ($class, $importer) = @_;

	delete $Importers{$importer};
}

# addImporter takes hash ref of named function refs.
sub addImporter {
	my ($class, $importer, $params) = @_;

	$Importers{$importer} = $params;

	$::d_import && msgf("Import: Adding %s Scan\n", $importer);
}

sub runImporter {
	my ($class, $importer, $import) = @_;

	if ($Importers{$importer}->{'use'}) {

		if (!defined $import || (defined $import && ($importer eq $import))) {

			$importsRunning{$importer} = Time::HiRes::time();

			# rescan each enabled Import, or scan the newly enabled Import
			$::d_import && msgf("Import: Starting %s scan\n", $importer);

			$importer->startScan;
		}
	}
}

sub countImporters {
	my $class = shift;
	my $count = 0;

	for my $importer (keys %Importers) {
		
		# Don't count Folder Scan for this since we use this as a test to see if any other importers are in use
		if ($Importers{$importer}->{'use'} && $importer ne $folderScanClass) {

			$count++;
		}
	}

	return $count;
}

sub resetSetupGroups {
	my $class = shift;

	$class->walkImporterListForFunction('setup');
}

sub resetImporters {
	my $class = shift;

	$class->walkImporterListForFunction('reset');
}

sub walkImporterListForFunction {
	my $class    = shift;
	my $function = shift;

	for my $importer (keys %Importers) {

		if (defined $Importers{$importer}->{$function}) {
			&{$Importers{$importer}->{$function}};
		}
	}
}

sub importers {
	my $class = shift;

	return \%Importers;
}

sub useImporter {
	my ($class, $importer, $newValue) = @_;

	if (!$importer) {
		return 0;
	}

	if (defined $newValue && exists $Importers{$importer}) {

		$Importers{$importer}->{'use'} = $newValue;

	} else {

		return exists $Importers{$importer} ? $Importers{$importer} : 0;
	}
}

# End the main importers, such as Music Dir, iTunes, etc - and call
# post-processing steps in order if required.
sub endImporter {
	my ($class, $importer) = @_;

	if (exists $importsRunning{$importer}) { 

		$::d_import && msgf("Import: Completed %s Scan in %s seconds.\n",
			$importer, int(Time::HiRes::time() - $importsRunning{$importer})
		);

		delete $importsRunning{$importer};
	}
}

sub stillScanning {
	my $class    = shift;
	my $imports  = scalar keys %importsRunning;

	# Check and see if there is a flag in the database, and the process is alive.
	my $scanRS   = Slim::Schema->single('MetaInformation', { 'name' => 'isScanning' });
	my $scanning = blessed($scanRS) ? $scanRS->value : 0;

	my $running  = blessed($class->scanningProcess) && $class->scanningProcess->alive ? 1 : 0;

	if ($running || $scanning) {
		return 1;
	}

	return 0;
}

1;

__END__

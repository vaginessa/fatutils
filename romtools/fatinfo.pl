#!perl -w
use strict;
# (C) 2003 XDA Developers
# Author: Willem Jan Hengeveld <itsme@xs4all.nl>
# Web: http://www.xda-developers.com/
#
# $Header$
#
# script to extract deleted files / unused space from a fat filesystem
#  ( for instance the xda2 extended rom upgrade file )
#
# shortcomings:
#    - does not yet support subdirectories.
# 

$|=1;

use IO::File;
use Getopt::Long;
use File::Path;

my $g_saveFilesTo;
my $g_saveDeletedFiles;
my $g_saveUnusedClusters;
my $g_saveLeftoverSize;
my $g_fatOffset= 0;
my $g_verbose= 0;
my $g_quiet= 0;
my $g_repair= 0;

my @g_repaircmds;

sub usage {
    return <<__EOF__
Usage: perl fatinfo.pl [options]  fatfilesystemimage
   -f DIRECTORY  : save files to DIRECTORY
   -d            : save deleted files
   -c            : save unused clusters
   -l            : save data from unused cluster space
   -o OFFSET     : offset to FAT bootsector
   -v            : be verbose
   -r            : repair incorrect filesize (only rootdir entries)

for example to print info on the xda-ii extended rom image:

    perl fatinfo.pl -o 0x70040 ms_.nbf

__EOF__
}
GetOptions(
    "f=s" => \$g_saveFilesTo,
    "d" => \$g_saveDeletedFiles,
    "c" => \$g_saveUnusedClusters,
    "l" => \$g_saveLeftoverSize,
    "v" => \$g_verbose,
    "q" => \$g_quiet,
    "r" => \$g_repair,
    "o=s" => sub { $g_fatOffset= eval $_[1]; },
) or die usage();

die usage() if (!@ARGV);

my $extromname= shift;
my $fh= new IO::File($extromname, "r") or die "$extromname: $!\n";
binmode $fh;

if (!$g_fatOffset) {
	FindFatOffset($fh);
}
my $bootinfo= ReadBootInfo($fh);

if ($bootinfo->{ReservedSectors}) {
    $fh->seek(($bootinfo->{ReservedSectors}-1)*$bootinfo->{BytesPerSector}, SEEK_CUR);
}
my @fats;

for (0 .. $bootinfo->{NumberOfFats}-1) {
	$fats[$_]= ReadFat($fh, $bootinfo->{SectorsPerFAT}, $bootinfo->{FSID});
}

print "found ", scalar keys %{$fats[0]}, " files in fat\n" if (!$g_quiet);

$bootinfo->{rootdirofs}= $fh->tell();

printf("reading rootdir from %08lx\n", $bootinfo->{rootdirofs}) if (!$g_quiet);

$bootinfo->{cluster2sector}= $bootinfo->{RootEntries}/16 + $bootinfo->{SectorsPerFAT}*$bootinfo->{NumberOfFats} + 1;

$bootinfo->{totalclusters}= int(($bootinfo->{NumberOfSectors}-$bootinfo->{cluster2sector})/$bootinfo->{SectorsPerCluster});

$fh->seek($bootinfo->{rootdirofs}, SEEK_SET);
my $rootnsects= $bootinfo->{RootEntries}?$bootinfo->{RootEntries}/16:1;
my $rootdata;
$fh->read($rootdata, $rootnsects*$bootinfo->{BytesPerSector}) or die sprintf("error reading rootdir\n");
processdir($fh, $bootinfo, $bootinfo->{rootdirofs}, $rootdata, "");


SaveUnusedClusters($fh, $bootinfo, $fats[0]) if ($g_saveUnusedClusters);

$fh->close();

# parameters:
#   fh: handle to file containing fat image
#   bootinfo: params from bootsector
#   ofs: offset to this directory, relative to start of fat image.
#   data: data containing dir entries.
sub processdir {
    my ($fh, $bootinfo, $ofs, $data, $path)= @_;

    my $dir= ParseDirectory($ofs, $data);

    printf("\n directory %s\n\n", $path||"/");
    PrintDir($fats[0], $dir, $bootinfo);

    SaveFiles($fh, $bootinfo, $fats[0], $dir, $path) if ($g_saveFilesTo);

	for my $dirent (@$dir) {
        if ($dirent->{attribute}&0x10) {
            next if ($dirent->{filename} eq ".." || $dirent->{filename} eq "." );

            my $dirdata= ReadClusterChain($fh, $bootinfo, $fats[0], $dirent->{start});
            my $dirofs= (($dirent->{start}-2)*$bootinfo->{SectorsPerCluster}+$bootinfo->{cluster2sector})*$bootinfo->{BytesPerSector};
            processdir($fh, $bootinfo, $dirofs, $dirdata, $path."/".($dirent->{lfn}||$dirent->{filename}));
        }
    }
}


if ($g_repair && @g_repaircmds) {
    print "\nto repair your disk run these commands:\n\n";
    print "hexedit $extromname @g_repaircmds\n";
    printf("psdwrite -2 %s -s 0x%x  0x%x\n", $extromname, $bootinfo->{rootdirofs}, $bootinfo->{rootdirofs}); 
}
exit(0);

sub FindFatOffset {
	my ($fh)= @_;

	for (0, 0x40, 0x70000, 0x70040) {
		if (isFatBoot($fh, $_)) {
			$g_fatOffset= $_;
			return;
		}
	}
}
sub isFatBoot {
	my ($fh, $ofs)= @_;
	my $data;
	$fh->seek($ofs, SEEK_SET);
	$fh->read($data, 128);

	return substr($data, 3, 8) eq "MSWIN4.1"
		&& ( substr($data, 54, 8) eq "FAT16   "
		    || substr($data, 54, 8) eq "FAT12   "
            || substr($data, 82, 8) eq "FAT32   " );
}

sub ReadBootInfo {
	my ($fh)= @_;

    $fh->seek($g_fatOffset, 0);

    printf("reading bootsector from %08lx\n", $fh->tell()) if (!$g_quiet);

	my $data;
	$fh->read($data, 512) or die "error reading bootsector\n";

    my @fields;
    my @fieldnames;
    if ($data =~ /FAT32/) {
        @fields= unpack("A3A8vCvCvvCvvvVVVvvVvvA12CCCVA11A8a*", $data);

        @fieldnames= qw(Jump OEMID BytesPerSector SectorsPerCluster ReservedSectors NumberOfFats RootEntries NumberOfSectors MediaDescriptor oldSectorsPerFAT SectorsPerHead HeadsPerCylinder HiddenSectors BigNumberOfSectors SectorsPerFAT Flags Version StartOfRootDir FSISector BackupBootSector reserved PhysicalDrive unused Signature SerialNumber VolumeLabel FSID executablecode);
    }
    else {
        @fields= unpack("A3A8vCvCvvCvvvVVCCCVA11A8a*", $data);

        @fieldnames= qw(Jump OEMID BytesPerSector SectorsPerCluster ReservedSectors NumberOfFats RootEntries NumberOfSectors MediaDescriptor SectorsPerFAT SectorsPerHead HeadsPerCylinder HiddenSectors BigNumberOfSectors PhysicalDrive CurrentHead Signature SerialNumber VolumeLabel FSID reserved);
    }
    print "field count mismatch($#fields != $#fieldnames)\n" if ($#fields != $#fieldnames);

	my %bootinfo= map { $fieldnames[$_] => $fields[$_] } (0..$#fields);

    if (!$g_quiet) {
        printf("%-11s      : %s\n", $fields[1], $fieldnames[1]);
        for (2..$#fieldnames-4) {
            next if ($fieldnames[$_] eq "reserved");
            printf("%8x (%5d) : %s\n", $fields[$_], $fields[$_], $fieldnames[$_]);
        }
        printf("%-10s       : %s\n", $fields[-3], $fieldnames[-3]);
        printf("%-10s       : %s\n", $fields[-2], $fieldnames[-2]);

        print(unpack("H*", $fields[-1]), "\n") if ($fields[-1] !~ /^\x00+\x55\xaa$/);
    }

	return \%bootinfo;
}

# assumes filepointer points after bootsector
sub ReadFat {
	my ($fh, $sects, $fsid)= @_;

    printf("reading fat from %08lx\n", $fh->tell()) if (!$g_quiet);

	my $data;
	$fh->read($data, 512*$sects) or die "error reading ReadFat\n";

    my @clusters;
    my $clusterspecial;
    if ($fsid =~ /FAT16/) {
        @clusters= unpack("v*", $data);
        $clusterspecial=0xfff0;
        print "detected FAT16\n";
    }
    elsif ($fsid =~ /FAT32/) {
        @clusters= unpack("V*", $data);
        $clusterspecial= 0xff00000;
        print "detected FAT32\n";
    }
    elsif ($fsid =~ /FAT12/) {
        die "fat12 not yet implemented\n";
    }

    my $maxused;
    my %ref;
    for (0..$#clusters) {
        if ($clusters[$_]>0 && $clusters[$_]<$clusterspecial) {
            $ref{$clusters[$_]}= 1;

        }
        if ($clusters[$_]) {
            $maxused= $_;
        }
    }

	printf("found %d clusters, max used= %04x\n", scalar @clusters, $maxused) if (!$g_quiet);

	my %emptylist;
	my %files;
	for (0..$#clusters) {
		if (!exists $ref{$_} && $clusters[$_]>0) {
			my @list= ();

			for (my $clus= $_ ; $clus>0 && $clus<$clusterspecial ; $clus= $clusters[$clus]) {
				push @list, $clus;
			}
			$files{$_}{clusterlist}= \@list;
		}
		elsif ($clusters[$_]==0) {
			$emptylist{$_}= 1;
		}
	}
	$files{emptylist}= \%emptylist;
	$files{ref}= \%ref;
	return \%files;
}
sub ParseLFNEntry {
	my ($dirdata)= @_;

    # 00  bits5-0=partnr  bit6=last   bit7 = erased.
    # 01  namepart1 - 5 unicode chars
    # 0b  0x0f
    # 0c  ?  0x00
    # 0d  ?  checksum of shortname
    # 0e  namepart2 - 6 unicode chars
    # 1a  ?  0x0000
    # 1c  namepart3 - 2 unicode chars

    #print "hex: ", unpack("H*", $dirdata), "\n";
	my @fields= unpack("Ca10CCCa12va4", $dirdata);
	my $unicodename= $fields[1].$fields[5].$fields[7];
    #print join(", ", map {sprintf("%d:%s", $_, unpack("H*",$fields[$_])) } (0..$#fields)), "\n";

	my $namepart= pack("C*", grep { $_<256 } unpack("v*", $unicodename));

	$namepart =~ s/\x00.*//;

    #printf("LFN part %2d  last=%d name=%s\n", $fields[0]&0x3f, $fields[0]&0x40, $namepart );
	return { part=>$fields[0]&0x3f, last=>$fields[0]&0x40, namepart=>$namepart };
}

sub ParseDirEntry {
	my ($dirdata)= @_;

    # 00 filenameext
    # 0b attrib         != 0x0f
    # 0c reserved
    #  0c  first char of erased filename.
    #  0d  10ms createtime.
    #  0e  creation time
    #  10  creation date
    #  12  access date
    #  14  high 16 bits of cluster nr (fat32)
    # 16 time
    # 18 date
    # 1a startcluster
    # 1c filesize

    #print "hex: ", unpack("H*", $dirdata), "\n";

	my @fieldnames= qw(filename attribute erasedchar creationstamp accessdate highstart time date start filesize);
	my @fields= unpack("A11CCa5vvvvvV", $dirdata);
	print "dirfield count mismatch($#fields != $#fieldnames)\n" if ($#fields != $#fieldnames);
	my %direntry= map { $fieldnames[$_] => $fields[$_] } (0..$#fields);

	if ($direntry{attribute}==0xf) {
		return ParseLFNEntry($dirdata);
	}
	$direntry{filename} =~ s/^(\S+)\s*(...)$/$1.$2/;

	return \%direntry;
}

# 
# startofs: byte-offset relative to start of fat image.
#           ( used to calc disk offset of dir entry )
# data: datablock containing all dir entries
#
# RETURNS:
#   array of dir entries.
sub ParseDirectory {
	my ($startofs, $data)= @_;

	my @entries;
	my @lfn= ();
	for (0..length($data)/32-1) {
		my $entrydata= substr($data, 32*$_, 32);

		next if ($entrydata =~ /^\x00+$/);

		my $ent= ParseDirEntry($entrydata);

        # NOTE: this only works for rootdir entries.
        # other directories are not nescesarily stored in consequetive sectors.
        push @{$ent->{diskoffsets}}, $startofs+32*$_;

		if (exists $ent->{part}) {
			push @lfn, $ent->{namepart};
		}
		else {
			$ent->{lfn}= join("", reverse @lfn);
			push @entries, $ent;

            #printf("%d part lfn: %s\n", scalar @lfn, join(",",@lfn));
			@lfn= ();
		}
	}

	return \@entries;
}

sub CalcNrOfClusters {
    my ($size, $boot)= @_;
    my $clustersize= $boot->{SectorsPerCluster}*$boot->{BytesPerSector};
    return int(($size+$clustersize-1)/$clustersize);
}
sub ModifyFileSize {
    my ($ent, $size)= @_;

    # NOTE: this only works for rootdir entries.
    push @g_repaircmds, sprintf("-pd %08lx:%08lx", $ent->{diskoffsets}[0]+0x1c, $size);
}
sub isDirentry {
    my $ent= shift;
    return $ent->{attribute}&0x10;
}
sub PrintDirEntry {
	my ($fat, $ent, $boot)= @_;

    if (($ent->{attribute}&0x10)!=0 && $ent->{filesize}==0) {
        printf("%-12s %02x %04x-%04x %04x:%04x %8s  '%s'\n",
            $ent->{filename}, $ent->{attribute}, $ent->{time}, $ent->{date},
            $ent->{highstart}, $ent->{start}, "<DIR>", $ent->{lfn}) if (!$g_quiet);
    }
    else {
        printf("%-12s %02x %04x-%04x %04x:%04x %8d  '%s'\n",
            $ent->{filename}, $ent->{attribute}, $ent->{time}, $ent->{date},
            $ent->{highstart}, $ent->{start}, $ent->{filesize}, $ent->{lfn}) if (!$g_quiet);
    }
	if (!isDirentry($ent) &&  exists $fat->{$ent->{start}}) {
		my $nclusters= scalar @{$fat->{$ent->{start}}{clusterlist}};
		my $expectedclusters= CalcNrOfClusters($ent->{filesize}, $boot);
		if ($expectedclusters==$nclusters) {
			#printf("   has %d clusters\n", $nclusters);
		}
		else {
			printf("%s   has %d clusters, expected %d clusters\n", $ent->{lfn} || $ent->{filename}, $nclusters, $expectedclusters);

            if ($g_repair) {
                ModifyFileSize($ent, $nclusters*$boot->{SectorsPerCluster}*$boot->{BytesPerSector});
            }
		}
	}
	elsif (exists $fat->{emptylist}{$ent->{start}}) {
		printf("   is in emptylist\n") if ($g_verbose);
	}
}

sub PrintDir {
	my ($fat, $directory, $boot)= @_;

    print "8.3name    attr datetime start         size    longfilename\n" if (!$g_quiet);
	for (@$directory) {
		PrintDirEntry($fat, $_, $boot) if ($g_saveDeletedFiles || $g_verbose || !isDeletedEntry($_));
	}
}
sub isDeletedEntry {
    my ($ent)= @_;
    return $ent->{filename} =~ /^\xe5/;
}
sub GetUniqueName {
    my ($dir, $name)= @_;

    if (-e $dir && ! -d $dir) {
        die "not a directory: $dir\n";
    }
    mkpath $dir if (!-d $dir);

    my $fn= "$dir/$name";
    my $i= 1;
    while (-e $fn) {
        $fn= sprintf("%s/%s-%d", $dir, $name, $i++);
    }

    return $fn;
}
sub ReadClusterChain {
	my ($fh, $boot, $fat, $start)= @_;
    my $data= "";
    for (@{$fat->{$start}{clusterlist}})
    {
        $data .= ReadCluster($fh, $boot, $_);
        $fat->{ref}{$_}++;
    }
    return $data;
}
sub SaveEntry {
	my ($fh, $boot, $fat, $ent, $path)= @_;

	my $name= GetUniqueName("$g_saveFilesTo$path", $ent->{lfn} || $ent->{filename});
	my $outfh= IO::File->new($name, "w+") or die "$name: $!";
	binmode($outfh);
	if (exists $fat->{$ent->{start}}) {
		for (@{$fat->{$ent->{start}}{clusterlist}})
		{
			$outfh->write(ReadCluster($fh, $boot, $_));
			$fat->{ref}{$_}++;
		}
	}
	elsif (exists $fat->{emptylist}{$ent->{start}}) {
		my $nclusters= int(($ent->{filesize}+2047)/2048);
		for (0..$nclusters-1) {
			$outfh->write(ReadCluster($fh, $boot, $_+$ent->{start}));

			$fat->{ref}{$_}++;
		}
	}
	my $leftoversize= $outfh->tell()-$ent->{filesize};
	if ($g_saveLeftoverSize && $leftoversize>0) {
        printf("truncating last %d bytes for %s\n", $leftoversize, $name);
		$outfh->seek($ent->{filesize}, 0);
		my $leftoverdata;
		$outfh->read($leftoverdata, $leftoversize);

		my $leftfh= IO::File->new("$name-leftover", "w") or die "$name-leftover: $!";
		binmode($leftfh);
		$leftfh->write($leftoverdata);
		$leftfh->close();
	}
	$outfh->truncate($ent->{filesize});
	$outfh->close();

}
sub SaveFiles {
	my ($fh, $boot, $fat, $directory, $path)= @_;

	for (@$directory) {
        if (($_->{attribute}&0x10)==0) {
            SaveEntry($fh, $boot, $fat, $_, $path) if ($g_saveDeletedFiles || !isDeletedEntry($_));
        }
	}
}

sub ReadSector {
	my ($fh, $nr)= @_;

	$fh->seek($g_fatOffset+512*$nr, 0);

	my $data;
	$fh->read($data, 512);

	return $data;
}
sub ReadCluster {
	my ($fh, $boot, $nr)= @_;

	my $startsector= ($nr-2)*$bootinfo->{SectorsPerCluster}+$boot->{cluster2sector};

	my @data;

	for (0..$bootinfo->{SectorsPerCluster}-1) {
		push @data, ReadSector($fh, $startsector+$_);
	}

	return join "", @data;
}
sub SaveUnusedClusters {
	my ($fh, $boot, $fat)= @_;

	for (2 .. $boot->{totalclusters}-1) {
		next if (exists $fat->{ref}{$_});

        my $clusterfn= sprintf("$g_saveFilesTo/cluster-%04x", $_);
		my $outfh= IO::File->new($clusterfn, "w") or die "$clusterfn: $!";
		binmode($outfh);
		$outfh->write(ReadCluster($fh, $boot, $_));
		$outfh->close();
	}
}

#  fat12/fat16 bootsector layout
# 00 A3    Jump
# 03 A8    OEMID
# 0b v     BytesPerSector
# 0d C     SectorsPerCluster
# 0e v     ReservedSectors
# 10 C     NumberOfFats
# 11 v     RootEntries
# 13 v     NumberOfSectors
# 15 C     MediaDescriptor
# 16 v     SectorsPerFAT
# 18 v     SectorsPerHead
# 1a v     HeadsPerCylinder
# 1c V     HiddenSectors
# 20 V     BigNumberOfSectors
# 24 C     PhysicalDrive
# 25 C     CurrentHead
# 26 C     Signature
# 27 V     SerialNumber
# 2b A11   VolumeLabel
# 36 A8    FSID
# 3e a*    reserved

#  fat32 bootsector layout
# 00 A3    Jump
# 03 A8    OEMID
# 0b v     BytesPerSector
# 0d C     SectorsPerCluster
# 0e v     ReservedSectors
# 10 C     NumberOfFats
# 11 v     RootEntries
# 13 v     NumberOfSectors
# 15 C     MediaDescriptor
# 16 v     oldSectorsPerFAT
# 18 v     SectorsPerHead
# 1a v     HeadsPerCylinder
# 1c V     HiddenSectors
# 20 V     BigNumberOfSectors
# 24 V     SectorsPerFAT
# 28 v     Flags
# 2a v     Version
# 2c V     StartOfRootDir
# 30 v     FSISector
# 32 v     BackupBootSector
# 34 A12   reserved
# 40 C     PhysicalDrive
# 41 C     unused
# 42 C     Signature
# 43 V     SerialNumber
# 47 A11   VolumeLabel
# 52 A8    FSID
# 5a a*    executablecode

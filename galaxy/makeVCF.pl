#!/usr/bin/perl

# John M. Gaspar
# March 2015

# Construct a single VCF from VarScan pileup2snp, pileup2indel.

use strict;
use warnings;

sub usage {
  print q(Usage: perl makeVCF.pl  <infile1>  <infile2>  <infile3>  \
                <outfile>  <minQual>  <label>
  Required:
    <infile1>  Output from VarScan pileup2snp
    <infile2>  Output from VarScan pileup2indel
    <infile3>  Pileup file
    <outfile>  Output VCF file
  Optional:
    <minQual>  Minimum quality score used with VarScan
                 ('--min-avg-qual' parameter; def. 15)
    <label>    Sample name to add to header line
                 (def. <outfile>)
);
  exit;
}

usage() if (scalar @ARGV < 4 || $ARGV[0] eq "-h");

# open files
open(SNP, $ARGV[0]) || die "Cannot open $ARGV[0]\n";
open(IND, $ARGV[1]) || die "Cannot open $ARGV[1]\n";
open(PIL, $ARGV[2]) || die "Cannot open $ARGV[2]\n";
open(OUT, ">$ARGV[3]");

# minimum quality score
my $minQual = 15;
$minQual = $ARGV[4] if (scalar @ARGV > 4);
my $min = $minQual + 32;  # converted to ASCII

# sample name -- change '/' to '_' (for gemini compatibility)
my $samp = $ARGV[3];      
$samp = $ARGV[5] if (scalar @ARGV > 5);
$samp =~ tr/\//_/;

# print header of VCF file
print OUT q(##fileformat=VCFv4.2
##source=VarScan2,makeVCF.pl
##INFO=<ID=CIGAR,Number=1,Type=String,Description="CIGAR representation of the alternate allele">
##INFO=<ID=TYPE,Number=1,Type=String,Description="Type of alternate allele (sub, ins, or del)">
##FORMAT=<ID=AF,Number=1,Type=Float,Description="Allele frequency">
##FORMAT=<ID=AO,Number=1,Type=Integer,Description="Alternate allele observations">
##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Read depth (max. over reference positions)">
##FORMAT=<ID=RO,Number=1,Type=Integer,Description="Reference allele observations">
);
print OUT "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\t$samp\n";

# save read depth at each position
my %dp;
while (my $line = <PIL>) {
  chomp $line;
  my @spl = split("\t", $line);
  my $depth = 0;
  for (my $x = 0; $x < length $spl[5]; $x++) {
    # count only if quality is greater than min.
    $depth++ if (ord(substr($spl[5], $x, 1)) > $min);
  }
  $dp{$spl[0]}{$spl[1]} = $depth;
}
close PIL;

# skip headers
my $waste = <SNP>;
$waste = <IND>;

# save results
my %res;
my $iline = <IND>;
if ($iline) {
  chomp $iline;
} else {
  $iline = "chr99\t999999999";
}
my $sline = <SNP>;
if ($sline) {
  chomp $sline;
} else {
  $sline = "chr99\t999999999";
}

# print sorted output
while (1) {

  my @sar = split("\t", $sline);
  my @iar = split("\t", $iline);

  my $schr = substr($sar[0], 3);
  my $ichr = substr($iar[0], 3);
  $schr = 0 if ($schr eq 'M');
  $schr = 23 if ($schr eq 'X');
  $schr = 24 if ($schr eq 'Y');
  $ichr = 0 if ($ichr eq 'M');
  $ichr = 23 if ($ichr eq 'X');
  $ichr = 24 if ($ichr eq 'Y');
  last if ($schr == 99 && $ichr == 99);

  # determine which is next
  my $next = ($ichr < $schr ||
    ($ichr == $schr && $iar[1] < $sar[1]) ? 1 : 0);

  if ($next) {
    # in/del
    my @spl = split(/\//, $iar[3]);
    my $var = "";
    for (my $x = 0; $x < scalar @spl; $x++) {
      if ($spl[$x] ne '*') {
        die "In/del alleles don't match for $iline\n"
          if ($var && $var ne $spl[$x]);
        $var = $spl[$x];
      }
    }
    die "Cannot figure out in/del variant in $iline\n"
      if (! $var);
    my $del = substr($var, 0, 1);
    die "Cannot figure out in/del variant in $iline\n"
      if ($del ne '-' && $del ne '+');

    # construct ref/alt alleles and cigar
    my $ref = "";
    my $alt = "";
    my $cig = "1M";
    my $type = "";
    if ($del eq '-') {
      $ref = $iar[2] . substr($var, 1);
      $alt = $iar[2];
      $cig .= (-1 + length $var) . 'D';
      $type = "del"; 
    } else {
      $ref = $iar[2];
      $alt = $iar[2] . substr($var, 1);
      $cig .= (-1 + length $var) . 'I';
      $type = "ins"; 
    }

    my $ao = $iar[5];
    my $ro = $iar[4];

    # depth is max at any variant position
    my $len = length $ref;
    $len = 2 if (length $alt > $len);  # insertion: only count 2 positions
    my $dep = 0;
    for (my $x = 0; $x < $len; $x++) {
      $dep = $dp{$iar[0]}{$iar[1]+$x} if ($dp{$iar[0]}{$iar[1]+$x} > $dep);
    }

    # print output
    my $af = int(1000000*$ao/$dep+0.5) / 1000000;
    print OUT "$iar[0]\t$iar[1]\t.\t$ref\t$alt\t0\t.",
      "\tCIGAR=$cig;TYPE=$type",
      "\tAF:AO:DP:RO\t$af:$ao:$dep:$ro\n";

    # load next
    $iline = <IND>;
    if ($iline) {
      chomp $iline;
    } else {
      $iline = "chr99\t999999999";
    }

  } else {
    # substitution -- assume single base (SNP)
    my $ref = $sar[2];
    die "Cannot resolve SNP in $sline\n" if (length $ref > 1);
    my $alt = getAlt($sar[2], $sar[3]);
    my $ao = $sar[5];
    my $ro = $sar[4];
    my $dep = $dp{$sar[0]}{$sar[1]};
    my $af = int(1000000*$ao/$dep+0.5) / 1000000;
    my $cig = "1X";
    print OUT "$sar[0]\t$sar[1]\t.\t$ref\t$alt\t0\t.",
      "\tCIGAR=$cig;TYPE=sub",
      "\tAF:AO:DP:RO\t$af:$ao:$dep:$ro\n";

    # load next
    $sline = <SNP>;
    if ($sline) {
      chomp $sline;
    } else {
      $sline = "chr99\t999999999";
    }

  }
}
close OUT;
close SNP;
close IND;

# dissects IUPAC ambig code
sub getAlt {
  my $ref = $_[0];
  my $alt = $_[1];
  my $ret = "";

  $ret = $alt if ($alt eq 'A' || $alt eq 'C' ||
    $alt eq 'G' || $alt eq 'T');
  if ($ref eq 'A') {
    if ($alt eq 'M') {
      $ret = 'C';
    } elsif ($alt eq 'R') {
      $ret = 'G';
    } elsif ($alt eq 'W') {
      $ret = 'T';
    }
  } elsif ($ref eq 'C') {
    if ($alt eq 'M') {
      $ret = 'A';
    } elsif ($alt eq 'S') {
      $ret = 'G';
    } elsif ($alt eq 'Y') {
      $ret = 'T';
    }
  } elsif ($ref eq 'G') {
    if ($alt eq 'R') {
      $ret = 'A';
    } elsif ($alt eq 'S') {
      $ret = 'C';
    } elsif ($alt eq 'K') {
      $ret = 'T';
    }
  } elsif ($ref eq 'T') {
    if ($alt eq 'W') {
      $ret = 'A';
    } elsif ($alt eq 'Y') {
      $ret = 'C';
    } elsif ($alt eq 'K') {
      $ret = 'G';
    }
  }
  die "Cannot determine alt. allele for $ref, $alt\n"
    if (! $ret);
  return $ret;
}

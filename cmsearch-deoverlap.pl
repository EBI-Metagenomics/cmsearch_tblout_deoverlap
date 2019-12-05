#!/usr/bin/env perl
# 
# cmsearch-deoverlap.pl: remove lower scoring overlaps from cmsearch
#                        --tblout files.
#
# EPN, Mon May  8 08:41:36 2017
# 
#
# Without --maxkeep this script will exactly reproduce how cmscan removes overlapping hits.
# With --maxkeep, it won't. Here's an example to explain the difference:
#
##target name         accession query name           accession mdl mdl from   mdl to seq from   seq to strand trunc pass   gc  bias  score   E-value inc description of target
##------------------- --------- -------------------- --------- --- -------- -------- -------- -------- ------ ----- ---- ---- ----- ------ --------- --- ---------------------
#1. contig--151565       -         LSU_rRNA_eukarya     RF02543   hmm      632     2329      410     1883      +     -    6 0.48   1.1  726.0  1.1e-216 !   -
#2. contig--151565       -         LSU_rRNA_archaea     RF02540   hmm      170     2084       12     1882      +     -    6 0.47   3.0  490.0  2.3e-145 !   -
#3. contig--151565       -         LSU_rRNA_bacteria    RF02541   hmm      187     2005       10     1883      +     -    6 0.47   5.7  331.4   1.8e-97 !   -
#4. contig--151565       -         LSU_rRNA_eukarya     RF02543   hmm       29      431       12      366      +     -    6 0.41   7.8  100.0   6.3e-28 !   -
#
# hit 1: 410..1883 euk
# hit 2: 12..1182 arc
# hit 3: 10..1883 bac
# hit 4: 12..366 euk
#
# Without --maxkeep (default behavior) hits 2, 3, and 4 will be removed because for all 3, there is a better scoring hit
# that overlaps.
#
# With --maxkeep only hits 2 and 3 will be removed because only those 2 have
# higher scoring hits that overlap with them AND are not removed. If we remove only hits 2 and 3
# hits 1 and 4 no longer overlap.
#
use strict;
use warnings;
use Getopt::Long;

my $in_tblout  = "";   # name of input tblout file

my $usage;
$usage  = "cmsearch-deoverlap v0.07 [Dec 2019]\n\n";
$usage .= "Usage:\n\n";
$usage .= "cmsearch-deoverlap.pl    [OPTIONS] <tblout file>\n\tOR\n";
$usage .= "cmsearch-deoverlap.pl -l [OPTIONS] <list of tblout files>\n\n";
$usage .= "\tOPTIONS:\n";
$usage .= "\t\t-l             : single command line argument is a list of tblout files, not a single tblout file\n";
$usage .= "\t\t-s             : sort hits by bit score [default: sort by E-value]\n";
$usage .= "\t\t-d             : run in debugging mode (prints extra info)\n";
$usage .= "\t\t-v             : run in verbose mode (prints all removed and kept hits)\n";
$usage .= "\t\t--noverlap <n> : define an overlap as >= <n> or more overlapping residues [1]\n";
$usage .= "\t\t--nhmmer       : tblout files are from nhmmer v3.x\n";
$usage .= "\t\t--hmmsearch    : tblout files are from hmmsearch v3.x\n";
$usage .= "\t\t--cmscan       : tblout files are from cmscan v1.1x, not cmsearch\n";
$usage .= "\t\t--fcmsearch    : assert tblout files are cmsearch not cmscan\n";
$usage .= "\t\t--besthmm      : with --hmmsearch, sort by evalue/score of *best* single hit not evalue/score of full seq\n";
$usage .= "\t\t--clanin <s>   : only remove overlaps within clans, read clan info from file <s> [default: remove all overlaps]\n";
$usage .= "\t\t--maxkeep      : keep hits that only overlap with other hits that are not kept [default: remove all hits with higher scoring overlap]\n";
$usage .= "\t\t--dirty        : keep intermediate files (sorted tblout files)\n\n";

my $do_listfile      = 0;     # set to '1' if -l used
my $rank_by_score    = 0;     # set to '1' if -s used, rank by score, not evalues
my $do_debug         = 0;     # set to '1' if -d used
my $be_verbose       = 0;     # set to '1' if -v used
my $do_cmscan        = 0;     # set to '1' if --cmscan used
my $do_fcmsearch     = 0;     # set to '1' if --fcmsearch used
my $noverlap         = 1;     # set to <n> if --noverlap <n> used
my $in_clanin        = undef; # defined if --clanin option used
my $do_nhmmer        = 0;     # set to '1' if --nhmmer used, input tblout file(s) are from hmmer3's nhmmer
my $do_hmmsearch     = 0;     # set to '1' if --hmmsearch used, input tblout file(s) are from hmmer3's hmmsearch
my $do_besthmm       = 0;     # set to '1' if --besthmm used, sorting by evalue/score of best hit with --hmmsearch
my $do_maxkeep       = 0;     # set to '1' if --maxkeep, only remove hits that have 
                              # higher scoring overlap that is not removed
my $do_dirty         = 0;     # set to '1' if --dirty used, keep intermediate files

&GetOptions( "l"          => \$do_listfile, 
             "s"          => \$rank_by_score,
             "d"          => \$do_debug,
             "v"          => \$be_verbose,
             "cmscan"     => \$do_cmscan,
             "fcmsearch"  => \$do_fcmsearch,
             "noverlap=s" => \$noverlap,
             "nhmmer"     => \$do_nhmmer,
             "hmmsearch"  => \$do_hmmsearch,
             "besthmm"    => \$do_besthmm,
             "clanin=s"   => \$in_clanin,
             "maxkeep"    => \$do_maxkeep, 
             "keep"       => \$do_dirty);

if(scalar(@ARGV) != 1) { die $usage; }
($in_tblout) = @ARGV;

if($do_hmmsearch && $do_nhmmer) { 
  die "ERROR, --hmmsearch and --nhmmer cannot be used in combination. Pick one.";
}
if($do_besthmm && (! $do_hmmsearch)) { 
  die "ERROR, --besthmm requires --hmmsearch."; 
}  

my @tblout_file_A = ();

if($do_listfile) { 
  # read the list file
  my $list_file = $in_tblout;
  open(IN, $list_file) || die "ERROR unable to open $list_file for reading"; 
  while(my $line = <IN>) { 
    if($line =~ m/\w/ && $line !~ m/^\#/) { 
      chomp $line;
      if(! -e $line) { die "ERROR file $line read from $list_file does not exist"; }
      if(! -s $line) { die "ERROR file $line read from $list_file is empty"; }
      push(@tblout_file_A, $line);
    }
  }
  close(IN);
}
else { 
  $tblout_file_A[0] = $in_tblout;
}

my %clan_H = (); # key: model name, value: clan name
if(defined $in_clanin) { 
  %clan_H = ();
  parse_claninfo($in_clanin, \%clan_H)
}

my $sort_cmd           = undef; # command used to sort the tblout file
my $sorted_tblout_file = undef; # sorted tblout file to create, temporarily
my $output_file        = undef; # name of output file we create 
my $out_FH             = undef; # output file handle 
my $nkept              = undef; # number of sequences kept from a file 
my $nremoved           = undef; # number of sequences removed from a file 

foreach my $tblout_file (@tblout_file_A) { 
  if(! -e $tblout_file) { die "ERROR tblout file $tblout_file does not exist"; }
  if(! -s $tblout_file) { die "ERROR tblout file $tblout_file is empty"; }

  # if($rank_by_score): 
  #   sort tblout file by target sequence name, then score, then E-value 
  # else:
  #   sort tblout file by target sequence name, then E-value, then score
  #
  # keys to sort by depend on input tblout file type, which
  # is controlled by
  # $do_hmmsearch
  # $do_nhmmer
  # or default if both of those are false
  #
  $sorted_tblout_file = $tblout_file . ".sort";
  # the 'sed' calls replace multiple spaces with a single one, because sort is weird about multiple spaces sometimes
  if($do_hmmsearch) { 
    if($do_besthmm) { 
      $sort_cmd = ((defined $rank_by_score) && ($rank_by_score == 1)) ? 
          "grep -v ^\# $tblout_file | sed 's/  */ /g' | sort -k 1,1 -k 9,9rn -k 8,8g > $sorted_tblout_file" : 
          "grep -v ^\# $tblout_file | sed 's/  */ /g' | sort -k 1,1 -k 8,8g -k 9,9rn > $sorted_tblout_file";
    }
    else { # sort by full sequence evalue/score
      $sort_cmd = ((defined $rank_by_score) && ($rank_by_score == 1)) ? 
          "grep -v ^\# $tblout_file | sed 's/  */ /g' | sort -k 1,1 -k 6,6rn -k 5,5g > $sorted_tblout_file" : 
          "grep -v ^\# $tblout_file | sed 's/  */ /g' | sort -k 1,1 -k 5,5g -k 6,6rn > $sorted_tblout_file";
    }
  }
  elsif($do_nhmmer) { 
    $sort_cmd = ((defined $rank_by_score) && ($rank_by_score == 1)) ? 
        "grep -v ^\# $tblout_file | sed 's/  */ /g' | sort -k 1,1 -k 14,14rn -k 13,13g > $sorted_tblout_file" : 
        "grep -v ^\# $tblout_file | sed 's/  */ /g' | sort -k 1,1 -k 13,13g -k 14,14rn > $sorted_tblout_file";
  }
  elsif($do_cmscan) { 
    $sort_cmd = ((defined $rank_by_score) && ($rank_by_score == 1)) ? 
      "grep -v ^\# $tblout_file | sed 's/  */ /g' | sort -k 3,3 -k 15,15rn -k 16,16g > $sorted_tblout_file" : 
      "grep -v ^\# $tblout_file | sed 's/  */ /g' | sort -k 3,3 -k 16,16g -k 15,15rn > $sorted_tblout_file";
  }
  else { 
    # cmsearch, default
    $sort_cmd = ((defined $rank_by_score) && ($rank_by_score == 1)) ? 
      "grep -v ^\# $tblout_file | sed 's/  */ /g' | sort -k 1,1 -k 15,15rn -k 16,16g > $sorted_tblout_file" : 
      "grep -v ^\# $tblout_file | sed 's/  */ /g' | sort -k 1,1 -k 16,16g -k 15,15rn > $sorted_tblout_file";
  }
  run_command($sort_cmd, $do_debug);
  $output_file = $tblout_file . ".deoverlapped";
  $out_FH = undef;
  open($out_FH, ">", $output_file) || die "ERROR unable to open $output_file for writing"; 
  ($nkept, $nremoved) = parse_sorted_tblout_file($sorted_tblout_file, (defined $in_clanin) ? \%clan_H : undef, 
                                                 $do_cmscan, $do_nhmmer, $do_hmmsearch, $do_besthmm, $rank_by_score, $do_maxkeep, $do_debug, $be_verbose, $out_FH);
  close $out_FH;
  if(! $do_dirty) { 
    #unlink $sorted_tblout_file;
  }
  printf("Saved %5d hits (%5d removed) to $output_file\n", $nkept, $nremoved)
}

#################################################################
# Subroutine : parse_sorted_tblout_file()
# Incept:      EPN, Mon May  8 08:57:54 2017
#
# Purpose:     Parse a sorted tabular output file, and output
#              all hits that do not have a higher scoring overlap.
#              
# Arguments: 
#   $sorted_tbl_file:  file with sorted tabular search results
#   $clan_HR:          ref to hash of clan info, key is model, value is clan
#   $do_cmscan:        '1' if we're parsing cmscan tblout output
#   $do_nhmmer:        '1' if we're parsing nhmmer tblout output
#   $do_hmmsearch:     '1' if we're parsing hmmsearch tblout output
#   $do_besthmm:       '1' if we sorted hmmsearch tblout by best hit 
#                      not by full sequence
#   $rank_by_score:    '1' if rank is determined by score, '0' if
#                      determined by E-value
#   $do_maxkeep:       '1' if --maxkeep option used
#                      only remove hits with higher scoring overlaps
#                      *THAT ARE NOT THEMSELVES REMOVED*
#   $do_debug;         '1' if we should print debugging output
#   $be_verbose;       '1' if we should be verbose
#   $out_FH:           file handle to output to
#
# Returns:     Two values: 
#              $nkept:    number of hits saved and output
#              $nremoved: number of hits removed and not output
#
# Dies:        If we see a line of input that is an an unexpected
#              format
#
################################################################# 
sub parse_sorted_tblout_file { 
  my $nargs_expected = 11;
  my $sub_name = "parse_sorted_tblout_file";
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($sorted_tbl_file, $clan_HR, $do_cmscan, $do_nhmmer, $do_hmmsearch, $do_besthmm, $rank_by_score, $do_maxkeep, $do_debug, $be_verbose, $out_FH) = @_;

  my $prv_target = undef; # target name of previous line
  my $prv_score  = undef; # bit score of previous line
  my $prv_evalue = undef; # E-value of previous line
  my $clan       = undef; # clan of current model
  my $nkept      = 0;     # number of hits kept and output 
  my $nremoved   = 0;     # number of hits removed and not output 
  my $do_clans   = (defined $clan_HR) ? 1 : 0;

  open(IN, $sorted_tbl_file) || die "ERROR unable to open sorted tabular file $sorted_tbl_file for reading";

  my ($target, $tacc, $model, $macc, $domain, $mdlfrom, $mdlto, $seqfrom, $seqto, $strand, $score, $evalue) = 
      (undef, undef, undef, undef, undef, undef, undef, undef, undef, undef, undef, undef);

  my @line_A      = (); # array of output lines for kept hits for current sequence
  my @seqfrom_A   = (); # array of seqfroms for kept hits for current sequence
  my @seqto_A     = (); # array of seqtos for kept hits for current sequence
  my @strand_A    = (); # array of strands for kept hits for current sequence
  my @clan_A      = (); # array of clans for kept hits for current sequence
  my @keepme_A    = (); # array of '1' and '0', '1' if we should keep this hit, '0' if it had a higher scoring overlap
  my @noverlaps_A = (); # array of number of hits (lower scoring) that overlap with this sequence, **only valid for kept hits, -1 for removed hits**
  my $nhits       = 0;  # number of hits for current sequence (size of all arrays)

  my %already_seen_H = (); # hash, key is sequence name, value is '1' if we have output info for this sequence

  $prv_evalue = 0.;
  while(my $line = <IN>) { 
    ######################################################
    # Parse the data on this line, this differs depending
    # on our annotation method
    chomp $line;
    $line =~ s/^\s+//; # remove leading whitespace
    
    if($line =~ m/^\#/) { 
      die "ERROR, found line that begins with #, input should have these lines removed and be sorted by the first column:$line.";
    }
    
    if($do_hmmsearch) { 
      ($target, $model, $score, $evalue) = parse_hmmsearch_tblout_line($line, $do_besthmm);
      # hmmsearch --tblout output lacks sequence ranges and strand information
      # we want to allow only a single hit to the each target, so we set span as 1..1
      # so that all hits to the same target will 'overlap'. Strand is set as "+"
      # so all hits are considered on the same 'strand' for de-overlapping purposes.
      $seqfrom = 1;
      $seqto   = 1;
      $strand  = "+"; # no strand for hmmsearch output, so we assert + for de-overlapping purposes
    }
    elsif($do_nhmmer) { 
      ($target, $model, $seqfrom, $seqto, $strand, $score, $evalue) = parse_nhmmer_tblout_line($line);
    }
    elsif($do_cmscan) { 
      # call parse_cmsearch_tblout_line, just reverse $model and $target
      ($model, $macc, $target, $tacc, $seqfrom, $seqto, $strand, $score, $evalue) = parse_cmsearch_tblout_line($line);
    }
    else { # default: cmsearch 
      ($target, $tacc, $model, $macc, $seqfrom, $seqto, $strand, $score, $evalue) = parse_cmsearch_tblout_line($line);
      if((! $do_fcmsearch) && ($tacc =~ /^RF\d+/)) { 
        die "ERROR, target accession $tacc looks like an Rfam accession suggesting this is cmscan tblout output,\ndid you mean to use --cmscan? Use --fcmsearch to assert this is cmsearch output and avoid this error.\n";
      }
    }

    $clan = undef;
    if(defined $clan_HR) { 
      if(exists $clan_HR->{$model}) { 
        $clan = $clan_HR->{$model};
      }
    }

    # make sure we didn't output information for this sequence already
    if(exists $already_seen_H{$target}) { 
      die "ERROR found line with target $target previously output, did you sort by sequence name?";
    }

    ##############################################################
    # Are we now finished with the previous sequence? 
    # Yes, if target sequence we just read is different from it
    # If yes, output info for it, and re-initialize data structures
    # for new sequence just read
    if((defined $prv_target) && ($prv_target ne $target)) { 
      output_one_target($out_FH, $be_verbose, \@line_A, \@keepme_A, \@noverlaps_A);
      $already_seen_H{$prv_target} = 1; 
      @line_A      = ();
      @seqfrom_A   = ();
      @seqto_A     = ();
      @strand_A    = ();
      @clan_A      = ();
      @keepme_A    = ();
      @noverlaps_A = ();
      $nhits       = 0;
    }
    else { # this is not a new sequence
      if(defined $prv_target) { 
        # make sure that our current score or E-value is less than previous
        if($rank_by_score && ($score > $prv_score)) { 
          die "ERROR found lines with same target [$target] incorrectly sorted by score, did you sort by sequence name and score?";
        }
        elsif((! $rank_by_score) && ($evalue < $prv_evalue)) { 
          die "ERROR found lines with same target [$target] incorrectly sorted by E-value, did you sort by sequence name and E-value?";
        }
      }
    }
    ##############################################################

    # look through all other hits $i on the same strand and see if any of them overlap with this one
    # if (! $do_maxkeep) we look at all hits
    # if (  $do_maxkeep) we only look at hits that haven't been removed yet
    my $keep_me = 1; # set to '0' below if we find a better scoring hit
    my $overlap_idx = -1;
    for(my $i = 0; $i < $nhits; $i++) { 
      if(($strand_A[$i] eq $strand) &&                                # same strand
         (determine_if_clans_match($do_clans, $clan, $clan_A[$i])) && # clans match, or --clanin not used
         ((! $do_maxkeep) || ($keepme_A[$i] == 1))) {                 # either --maxkeep not enabled, or this hit is a keepter
        if(($strand eq "+") && (get_overlap($seqfrom, $seqto, $seqfrom_A[$i], $seqto_A[$i]) >= $noverlap)) { 
          $keep_me = 0;
          $overlap_idx = $i;
          $i = $nhits; # breaks for loop
        }
        elsif(($strand eq "-") && (get_overlap($seqto, $seqfrom, $seqto_A[$i], $seqfrom_A[$i]) >= $noverlap)) { 
          $keep_me = 0;
          $overlap_idx = $i;
          $i = $nhits; # breaks for loop
        }
      }
    }
    # add hit to list of hits we have for this sequence
    $line_A[$nhits]    = $line . "\n";
    $seqfrom_A[$nhits] = $seqfrom;
    $seqto_A[$nhits]   = $seqto;
    $strand_A[$nhits]  = $strand;
    $clan_A[$nhits]    = $clan;
    if($keep_me) { 
      $nkept++;
      $keepme_A[$nhits] = 1;
      $noverlaps_A[$nhits] = 0;
    }
    else { 
      $nremoved++;
      $keepme_A[$nhits] = 0;
      $noverlaps_A[$nhits] = -1;
      $noverlaps_A[$overlap_idx]++;
      if($do_debug) { 
        printf("target: $target model: $model: removing $seqfrom..$seqto, it overlapped with $seqfrom_A[$overlap_idx]..$seqto_A[$overlap_idx]\n");
      }
      if($be_verbose) { 
        printf("REMOVED                    $line\n");
        printf("BECAUSE-IT-OVERLAPPED-WITH $line_A[$overlap_idx]\n");
      }
    }
    $nhits++;
    $prv_target = $target;
    $prv_score  = $score;
    $prv_evalue = $evalue;
  }

  # output data for final sequence
  output_one_target($out_FH, $be_verbose, \@line_A, \@keepme_A, \@noverlaps_A);

  # close file handle
  close(IN);
  
  return ($nkept, $nremoved);
}

#################################################################
# Subroutine : output_one_target()
# Incept:      EPN, Mon May  8 10:20:40 2017
#
# Purpose:     Output all hits for a target. Overlapping hits 
#              are not included, they've been skipped.
#              
# Arguments: 
#   $out_FH:        file handle to output short output to (can be undef to not output short output)
#   $be_verbose:    '1' to output number of overlaps for each kept hit to stdout
#   $line_AR:       array of lines to output
#   $keepme_AR:     array of '1', '0', $keepme_AR->[$i]==1 indicates we should output $line_AR->[$i]
#   $noverlaps_AR:  array of '1', '0', $keepme_AR->[$i]==1 indicates we should output $line_AR->[$i]
#
# Returns:     Nothing.
# 
# Dies:        Never.
#
################################################################# 
sub output_one_target { 
  my $nargs_expected = 5;
  my $sub_name = "output_one_target";
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($out_FH, $be_verbose, $line_AR, $keepme_AR, $noverlaps_AR) = @_;

  for(my $i = 0; $i < scalar(@{$line_AR}); $i++) { 
    if($keepme_AR->[$i]) { 
      print $out_FH $line_AR->[$i]; 
      if($be_verbose) { printf("NUM-OVERLAPS:%d $line_AR->[$i]", $noverlaps_AR->[$i]) };
    }
  }

  return;
}

#################################################################
# Subroutine : determine_if_clans_match()
# Incept:      EPN, Mon May  8 10:28:41 2017
#
# Purpose:     Given two clan values return true if they 
#              either match or if the --clanin option is
#              not used.
#              
# Arguments: 
#   $do_clans: '1' if the --clanin option was used
#   $clan1:    clan 1, can be undef
#   $clan2:    clan 2, can be undef
#
# Returns:     '1' if the clans match or if $do_clans is FALSE
# 
# Dies:        Never.
#
################################################################# 
sub determine_if_clans_match { 
  my $nargs_expected = 3;
  my $sub_name = "determine_if_clans_match";
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($do_clans, $clan1, $clan2) = @_;

  if(! $do_clans) { 
    return 1; 
  }
  elsif((! defined $clan1) || (! defined $clan2)) { 
    # 1 or both of $clan1 and $clan2 are undefined, can't be a match
    return 0;
  }
  elsif($clan1 eq $clan2) { 
    # equal clans
    return 1;
  }
  else { 
    return 0;
  }
  
}

#################################################################
# Subroutine: get_overlap()
# Incept:     EPN, Mon Mar 14 13:47:57 2016 [dnaorg_scripts:dnaorg.pm:getOverlap()]
#
# Purpose:    Calculate number of nucleotides of overlap between
#             two regions.
#
# Args:
#  $start1: start position of hit 1 (must be <= $end1)
#  $end1:   end   position of hit 1 (must be >= $end1)
#  $start2: start position of hit 2 (must be <= $end2)
#  $end2:   end   position of hit 2 (must be >= $end2)
#
# Returns:  $noverlap:    Number of nucleotides of overlap between hit1 and hit2, 
#                         0 if none
#
# Dies:     if $end1 < $start1 or $end2 < $start2.
sub get_overlap {
  my $sub_name = "get_overlap";
  my $nargs_exp = 4;
  if(scalar(@_) != 4) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($start1, $end1, $start2, $end2) = @_; 

  # printf("in $sub_name $start1..$end1 $start2..$end2\n");

  if($start1 > $end1) { die "ERROR in $sub_name start1 > end1 ($start1 > $end1)"; }
  if($start2 > $end2) { die "ERROR in $sub_name start2 > end2 ($start2 > $end2)"; }

  # Given: $start1 <= $end1 and $start2 <= $end2.
  
  # Swap if nec so that $start1 <= $start2.
  if($start1 > $start2) { 
    my $tmp;
    $tmp   = $start1; $start1 = $start2; $start2 = $tmp;
    $tmp   =   $end1;   $end1 =   $end2;   $end2 = $tmp;
  }
  
  # 3 possible cases:
  # Case 1. $start1 <=   $end1 <  $start2 <=   $end2  Overlap is 0
  # Case 2. $start1 <= $start2 <=   $end1 <    $end2  
  # Case 3. $start1 <= $start2 <=   $end2 <=   $end1
  if($end1 < $start2) { return (0); }                    # case 1
  if($end1 <   $end2) { return ($end1 - $start2 + 1); }  # case 2
  if($end2 <=  $end1) { return ($end2 - $start2 + 1); }  # case 3
  die "ERROR in $sub_name, unforeseen case in $start1..$end1 and $start2..$end2";

  return; # NOT REACHED
}

#################################################################
# Subroutine:  run_command()
# Incept:      EPN, Mon Dec 19 10:43:45 2016
#
# Purpose:     Runs a command using system() and exits in error 
#              if the command fails. If $be_verbose, outputs
#              the command to stdout. 
#
# Arguments:
#   $cmd:         command to run, with a "system" command;
#   $be_verbose:  '1' to output command to stdout before we run it, '0' not to
#
# Returns:    nothing
#
# Dies:       if $cmd fails
#################################################################
sub run_command {
  my $sub_name = "run_command()";
  my $nargs_expected = 2;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($cmd, $be_verbose) = @_;
  
  if($be_verbose) { 
    print ("Running cmd: $cmd\n"); 
  }

  system($cmd);

  if($? != 0) { 
    die "ERROR in $sub_name, the following command failed:\n$cmd\n";
  }

  return;
}

#################################################################
# Subroutine:  parse_claninfo()
# Incept:      EPN, Wed May 10 15:01:07 2017
#
# Purpose:     Parse a claninfo file and fill %{$clan_HR}.
#
# Arguments:
#   $claninfo_file: clan info file
#   $clan_HR:       ref to hash of clan info, key: model name, value: clan name
#
# Returns:    nothing
#
# Dies:       if $cmd fails
#################################################################
sub parse_claninfo { 
  my $sub_name = "parse_claninfo()";
  my $nargs_expected = 2;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($claninfo_file, $clan_HR) = @_;
  
  open(IN, $claninfo_file) || die "ERROR unable to open clan info file";

  %{$clan_HR} = ();

  while(my $line = <IN>) { 
    if($line !~ m/^#/) { 
      chomp $line;
      my @el_A = split(/\s+/, $line);
      # first element is clan name, all other elements are model names in that clan
      #CL00111	SSU_rRNA_bacteria SSU_rRNA_archaea SSU_rRNA_eukarya SSU_rRNA_microsporidia SSU_trypano_mito
      for(my $i = 1; $i < scalar(@el_A); $i++) { 
        if(exists $clan_H{$el_A[$i]}) { 
          die "ERROR in $sub_name, parsing clan info file $claninfo_file, read model $el_A[$i] more than once";
        }
        $clan_HR->{$el_A[$i]} = $el_A[0];
      }
    }
  }

  return;
}

#################################################################
# Subroutine:  parse_cmsearch_tblout_line()
# Incept:      EPN, Fri Dec  8 09:33:23 2017
#
# Purpose:     Given an infernal cmsearch --tblout line, 
#              return $target, $query, $seqfrom, $seqto, $strand, $score, $evalue.
#
#     # Example line
#     #target name         accession query name           accession mdl mdl from   mdl to seq from   seq to strand trunc pass   gc  bias  score   E-value inc description of target
#     #------------------- --------- -------------------- --------- --- -------- -------- -------- -------- ------ ----- ---- ---- ----- ------ --------- --- ---------------------
#     5S_rRNA-sample10     -         5S_rRNA              RF00001    cm        1      119        1      121      +    no    1 0.61   0.0  108.2   1.5e-27 !   -
#
# Arguments:
#   $line:  line to parse
#
# Returns:    $target:  name of target      (5S_rRNA-sample10)
#             $tacc:    target accession    (-)
#             $query:   query name          (5S_rRNA)
#             $qacc:    query accession     (RF00005)
#             $seqfrom: sequence from coord (1)
#             $seqto:   sequence to coord   (121)
#             $strand:  strand of hit       (+)
#             $score:   bit score of hit    (108.2)
#             $evalue:  E-value of hit      (1.5e-27)
#
# Dies:       if line has fewer than 18 space delimited characters
#################################################################
sub parse_cmsearch_tblout_line { 
  my $sub_name = "parse_cmsearch_tblout_line";
  my $nargs_expected = 1;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($line) = @_;
  
  my @el_A = split(/\s+/, $line);

  if(scalar(@el_A) < 18) { die "ERROR found less than 18 columns in cmsearch tabular output at line: $line"; }
  my ($target, $tacc, $query, $qacc, $seqfrom, $seqto, $strand, $score, $evalue) = 
      ($el_A[0], $el_A[1], $el_A[2], $el_A[3], $el_A[7], $el_A[8], $el_A[9],  $el_A[14], $el_A[15]);

  return($target, $tacc, $query, $qacc, $seqfrom, $seqto, $strand, $score, $evalue);
}

#################################################################
# Subroutine:  parse_nhmmer_tblout_line()
# Incept:      EPN, Fri Dec  8 09:42:28 2017
#
# Purpose:     Given an nhmmer --tblout line, 
#              return $target, $query, $seqfrom, $seqto, $strand, $score, $evalue.
#
#     # Example line
#     # target name        accession  query name           accession  hmmfrom hmm to alifrom  ali to envfrom  env to  sq len strand   E-value  score  bias  description of target
#     #------------------- ---------- -------------------- ---------- ------- ------- ------- ------- ------- ------- ------- ------ --------- ------ ----- ---------------------
#     5S_rRNA-sample10     -          5S_rRNA              RF00001          4     115       4     117       1     121     121    +     1.6e-17   53.3   4.8  -
#
# Arguments:
#   $line:  line to parse
#
# Returns:    $target: name of target       (5S_rRNA-sample10)
#             $tacc:    target accession    (-)
#             $query:   query name          (5S_rRNA)
#             $qacc:    query accession     (RF00005)
#             $seqfrom: ali from coord      (4)
#             $seqto:   ali to coord        (117)
#             $strand:  strand of hit       (+)
#             $score:   bit score of hit    (53.3)
#             $evalue:  E-value of hit      (1.6e-17)
#
# Dies:       if line has fewer than 16 space delimited characters
#################################################################
sub parse_nhmmer_tblout_line { 
  my $sub_name = "parse_nhmmer_tblout_line";
  my $nargs_expected = 1;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($line) = @_;
  
  my @el_A = split(/\s+/, $line);

  if(scalar(@el_A) < 16) { die "ERROR found less than 16 columns in nhmmer tabular output at line: $line"; }
  my ($target, $tacc, $query, $qacc, $seqfrom, $seqto, $strand, $evalue, $score) = 
      ($el_A[0], $el_A[1], $el_A[2], $el_A[3], $el_A[6], $el_A[7], $el_A[11], $el_A[12], $el_A[13]);

  return($target, $tacc, $query, $qacc, $seqfrom, $seqto, $strand, $score, $evalue);
}

#################################################################
# Subroutine:  parse_hmmsearch_tblout_line()
# Incept:      EPN, Fri Dec  8 09:47:19 2017
#
# Purpose:     Given an hmmsearch --tblout line, 
#              return $target, $query, $score, $evalue.
#
#     # Example line
#     #                                                               --- full sequence ---- --- best 1 domain ---- --- domain number estimation ----
#     # target name        accession  query name           accession    E-value  score  bias   E-value  score  bias   exp reg clu  ov env dom rep inc description of target
#     #------------------- ---------- -------------------- ---------- --------- ------ ----- --------- ------ -----   --- --- --- --- --- --- --- --- ---------------------
#     5S_rRNA-sample10     -          5S_rRNA              RF00001      1.1e-19   59.8   0.0   1.2e-19   59.7   0.0   1.0   1   0   0   1   1   1   1 -
#
# Arguments:
#   $line:             line to parse
#   $do_best:          '1' to return score and E-value of best hit, not full sequence
#                      '0' to return score and E-value of sequence, not best hit
#
# Returns:    $target: name of target       (5S_rRNA-sample10)
#             $query:  query name           (5S_rRNA)
#             $score:  bit score of sequence  (53.3)
#             $evalue: E-value of hit      (1.6e-17)
#
# Dies:       if line has fewer than 19 space delimited characters
#################################################################
sub parse_hmmsearch_tblout_line { 
  my $sub_name = "parse_hmmsearch_tblout_line";
  my $nargs_expected = 2;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($line, $do_best) = @_;
  
  my @el_A = split(/\s+/, $line);

  if(scalar(@el_A) < 19) { die "ERROR found less than 16 columns in nhmmer tabular output at line: $line"; }
  my ($target, $query, $full_evalue, $full_score, $best_evalue, $best_score) = 
      ($el_A[0], $el_A[2], $el_A[4], $el_A[5], $el_A[7], $el_A[8]);

  if($do_best) { 
    return ($target, $query, $best_score, $best_evalue);
  }
  # else
  return ($target, $query, $full_score, $full_evalue);
}

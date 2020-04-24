#!/usr/bin/env perl

####################################################################################################
#                                                                                                  #
# braker.pl                                                                                        #
# Pipeline for predicting genes with GeneMark-EX* and AUGUSTUS                                     #
#                                                                                                  #
# Authors: Katharina Hoff, Simone Lange, Mario Stanke, Alexandre Lomsadze, Tomas Bruna,            #
#          Mark Borodovsky                                                                         # 
#                                                                                                  #
# Contact: katharina.hoff@uni-greifswald.de                                                        #
#                                                                                                  #
#                                                                                                  #
# This script is under the Artistic Licence                                                        #
# (http://www.opensource.org/licenses/artistic-license.php)                                        #
#                                                                                                  #
# *EX = ES/ET/EP/ETP, currently distributed as GeneMark-ES/ET                                      #
####################################################################################################

use Getopt::Long;
use File::Compare;
use File::HomeDir;
use File::Copy;
use File::Path qw(make_path rmtree);
use Module::Load::Conditional qw(can_load check_install requires);
use Scalar::Util::Numeric qw(isint);
use POSIX qw(floor);
use List::Util qw[min max];
use Parallel::ForkManager;
use FindBin;
use lib "$FindBin::RealBin/.";
use File::Which;                    # exports which()
use List::MoreUtils qw( pairwise );
use File::Which qw(which where);    # exports which() and where()

use Cwd;
use Cwd 'abs_path';

use File::Spec::Functions qw(rel2abs);
use File::Basename qw(dirname basename);
use File::Copy;

use helpMod
    qw( find checkFile formatDetector relToAbs setParInConfig addParToConfig uptodate gtf2fasta clean_abort );
use Term::ANSIColor qw(:constants);

use strict;
use warnings;

my $usage = <<'ENDUSAGE';

braker.pl     Pipeline for predicting genes with GeneMark-EX and AUGUSTUS with
            RNA-Seq

SYNOPSIS

braker.pl [OPTIONS] --genome=genome.fa --bam=rnaseq.bam

INPUT FILE OPTIONS

--genome=genome.fa                  fasta file with DNA sequences
--bam=rnaseq.bam                    bam file with spliced alignments from
                                    RNA-Seq
--hints=hints.gff                   Alternatively to calling braker.pl with a
                                    bam file, it is possible to call it with a
                                    file that contains introns extracted from
                                    RNA-Seq (or other data) in gff format.
                                    This flag also allows the usage of hints
                                    from additional extrinsic sources for gene
                                    prediction with AUGUSTUS. To consider such
                                    additional extrinsic information, you need
                                    to use the flag --extrinsicCfgFiles to
                                    specify parameters for all sources in the
                                    hints file (including the source "E" for
                                    intron hints from RNA-Seq). If you ran
                                    ProtHint before calling BRAKER, specify
                                    the files prothint_augustus.gff and
                                    evidence_augustus.gff, here.
--prothints=hints.gff               If BRAKER is called with hints produced
                                    by ProtHint, specify the file
                                    prothint.gff, here. Will possibly concatenated
                                    with hints RNA-Seq hints if called with
                                    --etpmode.
--evidence=evidence.gff             If BRAKER is called with hints produced
                                    by ProtHint, specify the file 
                                    evidence.gff, here. Will possibly be 
                                    concatenated with evidence from RNA-Seq
                                    if called with --etpmode.
--prot_seq=prot.fa                  A protein sequence file in multiple fasta
                                    format. This file will be used to generate
                                    protein hints for AUGUSTUS by running one
                                    of the three alignment tools Exonerate
                                    (--prg=exonerate), Spaln (--prg=spaln) or
                                    GenomeThreader (--prg=gth). Default is
                                    GenomeThreader if the tool is not
                                    specified.  Currently, hints from protein
                                    sequences are only used in the prediction
                                    step with AUGUSTUS.
--prot_aln=prot.aln                 Alignment file generated from aligning
                                    protein sequences against the genome with
                                    either Exonerate (--prg=exonerate), or
                                    Spaln (--prg=spaln), or GenomeThreader
                                    (--prg=gth).
                                    To prepare alignment file, run Spaln2 with
                                    the following command:
                                    spaln -O0 ... > spalnfile
                                    To prepare alignment file, run Exonerate
                                    with the following command:
                                    exonerate --model protein2genome \
                                        --showtargetgff T ... > exfile
                                    To prepare alignment file, run
                                    GenomeThreader with the following command:
                                    gth -genomic genome.fa  -protein \
                                        protein.fa -gff3out \
                                        -skipalignmentout ... -o gthfile
                                    A valid option prg=... must be specified
                                    in combination with --prot_aln. Generating
                                    tool will not be guessed.
                                    Currently, hints from protein alignment
                                    files are only used in the prediction step
                                    with AUGUSTUS.

FREQUENTLY USED OPTIONS

--species=sname                     Species name. Existing species will not be
                                    overwritten. Uses Sp_1 etc., if no species
                                    is assigned
--AUGUSTUS_ab_initio                output ab initio predictions by AUGUSTUS
                                    in addition to predictions with hints by
                                    AUGUSTUS
--softmasking                       Softmasking option for soft masked genome
                                    files. (Disabled by default.)
--esmode                            Run GeneMark-ES (genome sequence only) and 
                                    train AUGUSTUS on long genes predicted by 
                                    GeneMark-ES. Final predictions are ab initio
--epmode                            Run GeneMark-EP with intron hints provided
                                    from protein data. This mode is not 
                                    comptabile with using the aligners
                                    GenomeThreader, Exonerate and Spaln (stand alone) 
                                    within braker.pl. ProtHint (with Spaln) as 
                                    alignment producing software is compatible.
--etpmode                           Run GeneMark-ETP with hints provided from
                                    proteins and RNA-Seq data. This mode is not
                                    compatible with using the aligners
                                    GenomeThreader, Exonerate and Spaln (stand alone) 
                                    within braker.pl. ProtHint (with Spaln)
                                    as alignment poducing pipeline is 
                                    compatible.
--gff3                              Output in GFF3 format (default is gtf
                                    format)
--cores                             Specifies the maximum number of cores that
                                    can be used during computation. Be aware:
                                    optimize_augustus.pl will use max. 8
                                    cores; augustus will use max. nContigs in
                                    --genome=file cores.
--workingdir=/path/to/wd/           Set path to working directory. In the
                                    working directory results and temporary
                                    files are stored
--nice                              Execute all system calls within braker.pl
                                    and its submodules with bash "nice"
                                    (default nice value)

--alternatives-from-evidence=true   Output alternative transcripts based on
                                    explicit evidence from hints (default is
                                    true).
--crf                               Execute CRF training for AUGUSTUS;
                                    resulting parameters are only kept for
                                    final predictions if they show higher
                                    accuracy than HMM parameters.
--keepCrf                           keep CRF parameters even if they are not
                                    better than HMM parameters
--UTR=on                            create UTR training examples from RNA-Seq
                                    coverage data; requires options
                                    --bam=rnaseq.bam and --softmasking.
                                    Alternatively, if UTR parameters already
                                    exist, training step will be skipped and
                                    those pre-existing parameters are used.
--prg=ph|gth|exonerate|spaln        Alignment tool for generating hints from
                                    similarity of protein sequence data to
                                    genome data. Method ph (ProtHint with Spaln)
                                    is generally suitable; gth (GenomeThreader),
                                    exonerate (Exonerate) or Spaln2
                                    (spaln) are suitable for proteins of closely
                                    related species, only.
                                    This option should be specified correctly in 
                                    case --prot_seq or --prot_aln options are used
                                    (--prot_aln option is not required of hints
                                    for AUGUSTUS were generated with ProtHint, in
                                    that case, hints are provided with --hints=file
                                    and --prg=ph is not required).
--gth2traingenes                    Generate training gene structures for
                                    AUGUSTUS from GenomeThreader alignments.
                                    (These genes can either be used for
                                    training AUGUSTUS alone with
                                    --trainFromGth; or in addition to
                                    GeneMark-ET training genes if also a
                                    bam-file is supplied.)
--trainFromGth                      No GeneMark-Training, train AUGUSTUS from
                                    GenomeThreader alignments
--makehub                           Create track data hub with make_hub.py 
                                    for visualizing BRAKER results with the
                                    UCSC GenomeBrowser
--email                             E-mail address for creating track data hub
--version                           Print version number of braker.pl
--help                              Print this help message

CONFIGURATION OPTIONS (TOOLS CALLED BY BRAKER)

--AUGUSTUS_CONFIG_PATH=/path/       Set path to config directory of AUGUSTUS
                                    (if not specified as environment
                                    variable). BRAKER1 will assume that the
                                    directories ../bin and ../scripts of
                                    AUGUSTUS are located relative to the
                                    AUGUSTUS_CONFIG_PATH. If this is not the
                                    case, please specify AUGUSTUS_BIN_PATH
                                    (and AUGUSTUS_SCRIPTS_PATH if required).
                                    The braker.pl commandline argument
                                    --AUGUSTUS_CONFIG_PATH has higher priority
                                    than the environment variable with the
                                    same name.
--AUGUSTUS_BIN_PATH=/path/          Set path to the AUGUSTUS directory that
                                    contains binaries, i.e. augustus and
                                    etraining. This variable must only be set
                                    if AUGUSTUS_CONFIG_PATH does not have
                                    ../bin and ../scripts of AUGUSTUS relative
                                     to its location i.e. for global AUGUSTUS
                                    installations. BRAKER1 will assume that
                                    the directory ../scripts of AUGUSTUS is
                                    located relative to the AUGUSTUS_BIN_PATH.
                                    If this is not the case, please specify
                                    --AUGUSTUS_SCRIPTS_PATH.
--AUGUSTUS_SCRIPTS_PATH=/path/      Set path to AUGUSTUS directory that
                                    contains scripts, i.e. splitMfasta.pl.
                                    This variable must only be set if
                                    AUGUSTUS_CONFIG_PATH or AUGUSTUS_BIN_PATH
                                    do not contains the ../scripts directory
                                    of AUGUSTUS relative to their location,
                                    i.e. for special cases of a global
                                    AUGUSTUS installation.
--BAMTOOLS_PATH=/path/to/           Set path to bamtools (if not specified as
                                    environment BAMTOOLS_PATH variable). Has
                                    higher priority than the environment
                                    variable.
--GENEMARK_PATH=/path/to/           Set path to GeneMark-ET (if not specified
                                    as environment GENEMARK_PATH variable).
                                    Has higher priority than environment
                                    variable.
--SAMTOOLS_PATH=/path/to/           Optionally set path to samtools (if not
                                    specified as environment SAMTOOLS_PATH
                                    variable) to fix BAM files automatically,
                                    if necessary. Has higher priority than
                                    environment variable.
--ALIGNMENT_TOOL_PATH=/path/to/tool Set path to alignment tool
                                    (prothint.py, GenomeThreader, Spaln, or Exonerate)
                                    if not specified as environment
                                    ALIGNMENT_TOOL_PATH variable. Has higher
                                    priority than environment variable.
--DIAMOND_PATH=/path/to/diamond     Set path to diamond, this is an alternative
                                    to NCIB blast; you only need to specify one 
                                    out of DIAMOND_PATH or BLAST_PATH, not both.
                                    DIAMOND is a lot faster that BLAST and yields 
                                    highly similar results for BRAKER.
--BLAST_PATH=/path/to/blastall      Set path to NCBI blastall and formatdb
                                    executables if not specified as
                                    environment variable. Has higher priority
                                    than environment variable.
--PYTHON3_PATH=/path/to             Set path to python3 executable (if not 
                                    specified as envirnonment variable and if
                                    executable is not in your $PATH).
--MAKEHUB_PATH=/path/to             Set path to make_hub.py (if option --makehub
                                    is used).
--CDBTOOLS_PATH=/path/to            cdbfasta/cdbyank are required for running
                                    fix_in_frame_stop_codon_genes.py. Usage of
                                    that script can be skipped with option 
                                    '--skip_fixing_broken_genes'.


EXPERT OPTIONS

--augustus_args="--some_arg=bla"    One or several command line arguments to
                                    be passed to AUGUSTUS, if several
                                    arguments are given, separate them by
                                    whitespace, i.e.
                                    "--first_arg=sth --second_arg=sth".
--skipGeneMark-ES                   Skip GeneMark-ES and use provided
                                    GeneMark-ES output (e.g. provided with 
                                    --geneMarkGtf=genemark.gtf)
--skipGeneMark-ET                   Skip GeneMark-ET and use provided
                                    GeneMark-ET output (e.g. provided with 
                                    --geneMarkGtf=genemark.gtf)
--skipGeneMark-EP                   Skip GeneMark-EP and use provided
                                    GeneMark-EP output (e.g. provided with
                                    --geneMarkGtf=genemark.gtf)
--skipGeneMark-ETP                  Skip GeneMark-ETP and use provided
                                    GeneMark-ETP output (e.g. provided with
                                    --geneMarkGtf=genemark.gtf)
--geneMarkGtf=file.gtf              If skipGeneMark-ET is used, braker will by
                                    default look in the working directory in
                                    folder GeneMarkET for an already existing
                                    gtf file. Instead, you may provide such a
                                    file from another location. If geneMarkGtf
                                    option is set, skipGeneMark-ES/ET/EP/ETP is
                                    automatically also set.
--rounds                            The number of optimization rounds used in
                                    optimize_augustus.pl (default 5)
--skipAllTraining                   Skip GeneMark-EX (training and
                                    prediction), skip AUGUSTUS training, only
                                    runs AUGUSTUS with pre-trained and already
                                    existing parameters (not recommended).
                                    Hints from input are still generated.
                                    This option automatically sets
                                    --useexisting to true.
--useexisting                       Use the present config and parameter files
                                    if they exist for 'species'; will overwrite
                                    original parameters if BRAKER performs
                                    an AUGUSTUS training.
--filterOutShort                    It may happen that a "good" training gene,
                                    i.e. one that has intron support from
                                    RNA-Seq in all introns predicted by
                                    GeneMark-EX, is in fact too short. This flag
                                    will discard such genes that have
                                    supported introns and a neighboring
                                    RNA-Seq supported intron upstream of the
                                    start codon within the range of the
                                    maximum CDS size of that gene and with a
                                    multiplicity that is at least as high as
                                    20% of the average intron multiplicity of
                                    that gene.
--skipOptimize                      Skip optimize parameter step (not
                                    recommended).
--skipIterativePrediction           Skip iterative prediction in --epmode (does 
                                    not affect other modes, saves a bit of runtime)
--skipGetAnnoFromFasta              Skip calling the python3 script
                                    getAnnoFastaFromJoingenes.py from the
                                    AUGUSTUS tool suite. This script requires
                                    python3, biopython and re (regular 
                                    expressions) to be installed. It produces
                                    coding sequence and protein FASTA files 
                                    from AUGUSTUS gene predictions and provides
                                    information about genes with in-frame stop 
                                    codons. If you enable this flag, these files 
                                    will not be produced and python3 and 
                                    the required modules will not be necessary
                                    for running braker.pl.
--skip_fixing_broken_genes          If you do not have python3, you can choose
                                    to skip the fixing of stop codon including
                                    genes (not recommended).
--fungus                            GeneMark-EX option: run algorithm with
                                    branch point model (most useful for fungal
                                    genomes)
--rnaseq2utr_args=params            Expert option: pass alternative parameters
                                    to rnaseq2utr as string, default parameters:
                                    -r 76 -v 100 -n 15 -i 0.7 -m 0.3 -w 70 
                                    -c 100 -p 0.5 
--eval=reference.gtf                Reference set to evaluate predictions
                                    against (using evaluation scripts from GaTech)
--eval_pseudo=pseudo.gff3           File with pseudogenes that will be excluded 
                                    from accuracy evaluation (may be empty file)
--AUGUSTUS_hints_preds=s            File with AUGUSTUS hints predictions; will
                                    use this file as basis for UTR training;
                                    only UTR training and prediction is
                                    performed if this option is given.
--flanking_DNA=n                    Size of flanking region, must only be
                                    specified if --AUGUSTUS_hints_preds is given
                                    (for UTR training in a separate braker.pl 
                                    run that builds on top of an existing run)
--verbosity=n                       0 -> run braker.pl quiet (no log)
                                    1 -> only log warnings
                                    2 -> also log configuration
                                    3 -> log all major steps
                                    4 -> very verbose, log also small steps
--downsampling_lambda=d             The distribution of introns in training
                                    gene structures generated by GeneMark-EX
                                    has a huge weight on single-exon and
                                    few-exon genes. Specifying the lambda
                                    parameter of a poisson distribution will
                                    make braker call a script for downsampling
                                    of training gene structures according to
                                    their number of introns distribution, i.e.
                                    genes with none or few exons will be
                                    downsampled, genes with many exons will be
                                    kept. Default value is 2. 
                                    If you want to avoid downsampling, you have 
                                    to specify 0. 
--checkSoftware                     Only check whether all required software
                                    is installed, no execution of BRAKER
--nocleanup                         Skip deletion of all files that are typically not 
                                    used in an annotation project after 
                                    running braker.pl. (For tracking any 
                                    problems with a braker.pl run, you 
                                    might want to keep these files, therefore
                                    nocleanup can be activated.)
--genemark_hintsfile=hints.gff      Hints file for GeneMark-ETP produced by a
                                    previous BRAKER run. Excluding contents or
                                    evidence.gff.


DEVELOPMENT OPTIONS (PROBABLY STILL DYSFUNCTIONAL)

--splice_sites=patterns             list of splice site patterns for UTR
                                    prediction; default: GTAG, extend like this:
                                    --splice_sites=GTAG,ATAC,...
                                    this option only affects UTR training
                                    example generation, not gene prediction
                                    by AUGUSTUS
--overwrite                         Overwrite existing files (except for
                                    species parameter files) Beware, currently
                                    not implemented properly!
--extrinsicCfgFiles=file1,file2,... Depending on the mode in which braker.pl
                                    is executed, it may require one ore several
                                    extrinsicCfgFiles. Don't use this option
                                    unless you know what you are doing!
--stranded=+,-,+,-,...              If UTRs are trained, i.e.~strand-specific
                                    bam-files are supplied and coverage 
                                    information is extracted for gene prediction, 
                                    create stranded ep hints. The order of 
                                    strand specifications must correspond to the
                                    order of bam files. Possible values are
                                    +, -, .
                                    If stranded data is provided, ONLY coverage
                                    data from the stranded data is used to 
                                    generate UTR examples! Coverage data from 
                                    unstranded data is used in the prediction
                                    step, only.
                                    The stranded label is applied to coverage
                                    data, only. Intron hints are generated
                                    from all libraries treated as "unstranded"
                                    (because splice site filtering eliminates
                                    intron hints from the wrong strand, anyway).
--optCfgFile=ppx.cfg                Optional custom config file for AUGUSTUS
                                    for running PPX (currently not
                                    implemented)
--grass                             Switch this flag on if you are using braker.pl 
                                    for predicting genes in grasses with 
                                    GeneMark-EX. The flag will enable
                                    GeneMark-EX to handle GC-heterogenicity
                                    within genes more properly.
                                    NOTHING IMPLEMENTED FOR GRASS YET!
--transmasked_fasta=file.fa         Transmasked genome FASTA file for GeneMark-EX
                                    (to be used instead of the regular genome
                                    FASTA file).  
--min_contig=INT                    Minimal contig length for GeneMark-EX, could
                                    for example be set to 10000 if transmasked_fasta
                                    option is used because transmasking might
                                    introduce many very short contigs.
--translation_table=INT             Change translation table from non-standard
                                    to something else. 
                                    DOES NOT WORK YET BECAUSE BRAKER DOESNT
                                    SWITCH TRANSLATION TABLE FOR GENEMARK-EX, YET!
--gc_probability=DECIMAL            Probablity for donor splice site pattern GC 
                                    for gene prediction with GeneMark-EX,
                                    default value is 0.001


DESCRIPTION

Example:


braker.pl [OPTIONS] --genome=genome.fa --species=speciesname \
    --bam=accepted_hits.bam
braker.pl [OPTIONS] --genome=genome.fa --species=speciesname \
    --hints=rnaseq.gff

To run with protein data from remote species and GeneMark-EP:

braker.pl [OPTIONS] --genome=genome.fa --hints=proteinintrons.gff --epmode=1

To run with protein data from a very closely related species:

braker.pl [OPTIONS] --genome=genome.fa --prot_seq=proteins.fa --prg=gth \
    --gth2traingenes --trainFromGth

ENDUSAGE

# Declartion of global variables ###############################################

my $v = 4; # determines what is printed to log
my $version = "2.1.5";
my $rootDir;
my $logString = "";          # stores log messages produced before opening log file
$logString .= "\#**********************************************************************************\n";
$logString .= "\#                               BRAKER CONFIGURATION                               \n";
$logString .= "\#**********************************************************************************\n";
$logString .= "\# BRAKER CALL: ". $0 . " ". (join " ", @ARGV) . "\n";
$logString .= "\# ". (localtime) . ": braker.pl version $version\n";
my $prtStr;
my $alternatives_from_evidence = "true";
                 # output alternative transcripts based on explicit evidence
                 # from hints
my $augpath;     # path to augustus
my $rnaseq2utr;
my $augustus_cfg_path;        # augustus config path, higher priority than
                              # $AUGUSTUS_CONFIG_PATH on system
my $augustus_bin_path;        # path to augustus folder binaries folder
my $augustus_scripts_path;    # path to augustus scripts folder
my $AUGUSTUS_CONFIG_PATH;
my $AUGUSTUS_BIN_PATH;
my $AUGUSTUS_SCRIPTS_PATH;
my $PYTHON3_PATH;
my $MAKEHUB_PATH;
my $CDBTOOLS_PATH;
my $cdbtools_path;
my $makehub_path;
my $email; # for make_hub.py
my @bam;                      # bam file names
my @stranded;                 # contains +,-,+,-... corresponding to 
                              # bam files
my $checkOnly = 0;
my $bamtools_path;
my $BAMTOOLS_BIN_PATH;
my $bool_species = "true";     # false, if $species contains forbidden words
my $cmdString;    # to store shell commands
my $CPU        = 1;      # number of CPUs that can be used
my $currentDir = cwd();  # working superdirectory where program is called from
my $errorfile;           # stores current error file name
my $errorfilesDir;       # directory for error files
my @extrinsicCfgFiles;    # assigned extrinsic files
my $extrinsicCfgFile;    # file to be used for running AUGUSTUS
my $extrinsicCfgFile1;   # user supplied file 1
my $extrinsicCfgFile2;   # user supplied file 2
my $extrinsicCfgFile3;   # user supplied file 3
my $extrinsicCfgFile4;   # user supplied file 4
my @files;               # contains all files in $rootDir
my $flanking_DNA;        # length of flanking DNA, default value is
                         # min{ave. gene length/2, 10000}
my @forbidden_words;     # words/commands that are not allowed in species name
my $fungus = 0;          # option for GeneMark-ET
my $gb_good_size;        # number of LOCUS entries in 'train.gb'
my $genbank;             # genbank file name
my $genemarkDir;         # directory for GeneMark-ET output
my $GENEMARK_PATH;
my $GMET_path;           # GeneMark-ET path
my $genome;              # name of sequence file
my %scaffSizes;          # length of scaffolds
my $gff3 = 0;            # create output file in GFF3 format
my $help;                # print usage
my @hints;               # input hints file names
my $hintsfile;           # hints file (all hints)
my $prot_hintsfile;      # hints file with protein hints
my $genemark_hintsfile;  # contains only intron hints in case $hintsfile also
                         # contains other hints types
my $gm_hints; # command line passed genemark_hintsfile from previous ETP run
my $limit = 10000000;    # maximum for generic species Sp_$limit
my $logfile;             # contains used shell commands
my $optCfgFile;          # optinonal extrinsic config file for AUGUSTUS
my $otherfilesDir;  # directory for other files besides GeneMark-ET output and
                    # parameter files
my $annot;          # reference annotation to compare predictions to
my $annot_pseudo;   # file with pseudogenes to be excluded from accuracy measurements
my %accuracy;       # stores accuracy results of gene prediction runs
my $overwrite = 0; # overwrite existing files (except for species parameter files)
my $parameterDir;     # directory of parameter files for species
my $perlCmdString;    # stores perl commands
my $printVersion = 0; # print version number, if set
my $SAMTOOLS_PATH;
my $SAMTOOLS_PATH_OP;    # path to samtools executable
my $scriptPath = dirname($0); # path of directory where this script is located
my $skipGeneMarkET = 0; # skip GeneMark-ET and use provided GeneMark-ET output
my $skipGeneMarkEP = 0; # skip GeneMark-EP and use provided GeneMark-EP output
my $skipGeneMarkETP = 0;
my $skipGeneMarkES = 0;
my $skipoptimize   = 0; # skip optimize parameter step
my $skipIterativePrediction;
my $skipAllTraining = 0;    # skip all training (including no GeneMark-EX run)
my $skipGetAnnoFromFasta = 0; # requires python3 & biopython
my $species;                # species name
my $soft_mask = 0;          # soft-masked flag
my $standard  = 0;          # index for standard malus/ bonus value
                            # (currently 0.1 and 1e1)
my $chunksize = 1252500;          # chunksize for running AUGUSTUS in parallel
my $stdoutfile;    # stores current standard output
my $string;        # string for storing script path
my $augustus_args; # string that stores command line arguments to be passed to
                   # augustus
my $testsize1;  # number of genes to test AUGUSTUS accuracy on after trainnig
my $testsize2;  # number of genes to test AUGUSTUS with during optimize_augustus.pl
my $useexisting
    = 0;        # use existing species config and parameter files, no changes
                # on those files
my $UTR = "off";    # UTR prediction on/off. currently not available für new
                    # species
my $workDir;        # in the working directory results and temporary files are
                    # stored
my $filterOutShort; # filterOutShort option (see help)
my $augustusHintsPreds; # already existing AUGUSTUS hints prediction without UTR
my $makehub; # flag for creating track data hub
my $evidence_hints; # input file from ProtHints for GeneMark-EP/ETP
my $prothint_file; # input file from ProtHints for GeneMark-EP/ETP

# Hint type from input hintsfile will be checked
# a) GeneMark-ET (requires intron hints) and
# b) selection of exrinsic.cfg file is affected by hint types
my @allowedHints = (
    "Intron",  "intron",  "start",    "stop",
    "ass",     "dss",     "exonpart", "exon",
    "CDSpart", "UTRpart", "nonexonpart", "ep"
);
# REMOVE Intron when GeneMark introns format has been fixed!

my $crf;     # flag that determines whether CRF training should be tried
my $keepCrf;
my $nice;    # flag that determines whether system calls should be executed
             # with bash nice (default nice value)
my ( $target_1, $target_2, $target_3, $target_4, $target_5) = 0;
                      # variables that store AUGUSTUS accuracy after different
                      # training steps
my $prg = "";              # variable to store protein alignment tool
my @prot_seq_files;   # variable to store protein sequence file name
my @prot_aln_files;   # variable to store protein alignment file name
my $ALIGNMENT_TOOL_PATH;
         # stores path to binary of gth, spaln or exonerate for running
         # protein alignments
my $ALIGNMENT_TOOL_PATH_OP;    # higher priority than environment variable
my $DIAMOND_PATH; # path to diamond, alternative to BLAST
my $diamond_path; # command line argument value for $DIAMOND_PATH
my $BLAST_PATH; # path to blastall and formatdb ncbi blast executable
my $blast_path; # command line argument value for $BLAST_PATH
my $python3_path; # command line argument value for $PYTHON3_PATH
my %hintTypes;    # stores hint types occuring over all generated and supplied
                  # hints for comparison
                  # additional parameters to be passed to rnaseq2utr
my $rnaseq2utr_args = "-r 76 -v 100 -n 15 -i 0.7 -m 0.3 -w 70 -c 100 -p 0.5 ";    
my $rounds = 5;   # rounds used by optimize_augustus.pl
my $geneMarkGtf;  # GeneMark output file (for skipGeneMark-ET option if not in
                  # braker working directory)
my $gth2traingenes; # Generate training genestructures for AUGUSTUS from
                    # GenomeThreader (can be used in addition to RNA-Seq
                    # generated training gene structures)
my $trainFromGth;   # No GeneMark-Training, train AUGUSTUS from GenomeThreader
                    # alignments, automatically sets --gth2traingenes
my $gthTrainGeneFile;    # gobally accessible file name variable
my $ESmode = 0; # flag for executing GeneMark-ES with genome sequence only
my $EPmode  = 0;    # flag for executing GeneMark-EP instead of GeneMark-ET
my $ETPmode = 0;  # flag for executing GeneMark-EPT
my $GeneMarkIntronThreshold;
   # use this value to screen hintsfile for GeneMark-EX. If few
   # hints with multiplicity higher than this value are
   # contained, braker will be aborted. Default value is determined by mode of
   # GeneMark-EX: currently 10 for ET and 4 for EP/EPT
my $ab_initio;    # flag for output of AUGUSTUS ab initio predictions
my $foundRNASeq = 0; # stores whether hintsfile contains src=E
my $foundProt = 0; # stores whether hintsfile contains src=P
my $lambda = 2; # labmda of poisson distribution for downsampling of training genes
my @splice_cmd_line;
my @splice;
my $AUGUSTUS_hints_preds; # for UTR training only (updating existing runs)
my $cleanup = 1; # enable file and directory cleanup after successful run
# list of forbidden words for species name
my $nocleanup;
my $transmasked_fasta; # transmaked genome file for GeneMark
my $min_contig; # min contig length for GeneMark, e.g. to be used in combination 
                # with transmasked_fasta
my $grass; # switch on GC treatment for GeneMark-ES/ET
my $ttable = 1; # translation table to be used
my $gc_prob = 0.001;
my $maxTrainGenes = 8000;
my $skip_fixing_broken_genes; # skip execution of fix_in_frame_stop_codon_genes.py
@forbidden_words = (
    "system",    "exec",  "passthru", "run",    "fork",   "qx",
    "backticks", "chmod", "chown",    "chroot", "unlink", "do",
    "eval",      "kill",  "rm",       "mv",     "grep",   "cd",
    "top",       "cp",    "for",      "done",   "passwd", "while",
    "nice", "ln"
);

if ( @ARGV == 0 ) {
    print "$usage\n";
    exit(0);
}

GetOptions(
    'alternatives-from-evidence=s' => \$alternatives_from_evidence,
    'AUGUSTUS_CONFIG_PATH=s'       => \$augustus_cfg_path,
    'AUGUSTUS_BIN_PATH=s'          => \$augustus_bin_path,
    'AUGUSTUS_SCRIPTS_PATH=s'      => \$augustus_scripts_path,
    'ALIGNMENT_TOOL_PATH=s'        => \$ALIGNMENT_TOOL_PATH_OP,
    'DIAMOND_PATH=s'               => \$diamond_path,
    'BLAST_PATH=s'                 => \$blast_path,
    'PYTHON3_PATH=s'               => \$python3_path,
    'CDBTOOLS_PATH=s'              => \$cdbtools_path,
    'MAKEHUB_PATH=s'               => \$makehub_path,
    'bam=s'                        => \@bam,
    'BAMTOOLS_PATH=s'              => \$bamtools_path,
    'cores=i'                      => \$CPU,
    'fungus!'                      => \$fungus,
    'extrinsicCfgFiles=s'           => \@extrinsicCfgFiles,
    'GENEMARK_PATH=s'              => \$GMET_path,
    'AUGUSTUS_hints_preds=s'       => \$AUGUSTUS_hints_preds,
    'genome=s'                     => \$genome,
    'gff3'                         => \$gff3,
    'hints=s'                      => \@hints,
    'optCfgFile=s'                 => \$optCfgFile,
    'overwrite!'                   => \$overwrite,
    'SAMTOOLS_PATH=s'              => \$SAMTOOLS_PATH_OP,
    'skipGeneMark-Es!'             => \$skipGeneMarkES,
    'skipGeneMark-ET!'             => \$skipGeneMarkET,
    'skipGeneMark-EP!'             => \$skipGeneMarkEP,
    'skipGeneMark-ETP!'            => \$skipGeneMarkETP,
    'skipOptimize!'                => \$skipoptimize,
    'skipIterativePrediction!'     => \$skipIterativePrediction,
    'skipAllTraining!'             => \$skipAllTraining,
    'skipGetAnnoFromFasta!'        => \$skipGetAnnoFromFasta,
    'species=s'                    => \$species,
    'softmasking!'                 => \$soft_mask,
    'useexisting!'                 => \$useexisting,
    'UTR=s'                        => \$UTR,
    'workingdir=s'                 => \$workDir,
    'filterOutShort!'              => \$filterOutShort,
    'crf!'                         => \$crf,
    'keepCrf!'                     => \$keepCrf,
    'nice!'                        => \$nice,
    'help!'                        => \$help,
    'prg=s'                        => \$prg,
    'prot_seq=s'                   => \@prot_seq_files,
    'prot_aln=s'                   => \@prot_aln_files,
    'augustus_args=s'              => \$augustus_args,
    'rnaseq2utr_args=s'            => \$rnaseq2utr_args,
    'rounds=s'                     => \$rounds,
    'geneMarkGtf=s'                => \$geneMarkGtf,
    'gth2traingenes!'              => \$gth2traingenes,
    'trainFromGth!'                => \$trainFromGth,
    'esmode!'                      => \$ESmode,
    'epmode!'                      => \$EPmode,
    'etpmode!'                     => \$ETPmode,
    'AUGUSTUS_ab_initio!'          => \$ab_initio,
    'eval=s'                       => \$annot,
    'eval_pseudo=s'                => \$annot_pseudo,
    'verbosity=i'                  => \$v,
    'downsampling_lambda=s'        => \$lambda,
    'splice_sites=s'               => \@splice_cmd_line,
    'flanking_DNA=i'               => \$flanking_DNA,
    'stranded=s'                   => \@stranded,
    'checkSoftware!'               => \$checkOnly,
    'nocleanup!'                   => \$nocleanup,
    'grass!'                       => \$grass,
    'transmasked_fasta=s'          => \$transmasked_fasta,
    'min_contig=s'                 => \$min_contig,
    'makehub!'                     => \$makehub,
    'email=s'                      => \$email,
    'version!'                     => \$printVersion,
    'translation_table=s'          => \$ttable,
    'skip_fixing_broken_genes!'    => \$skip_fixing_broken_genes,
    'gc_probability=s'             => \$gc_prob,
    'evidence=s'                   => \$evidence_hints,
    'prothints=s'                  => \$prothint_file,
    'genemark_hintsfile=s'         => \$gm_hints,
    'maxTrainGenes=i'              => \$maxTrainGenes
);

if ($help) {
    print $usage;
    exit(0);
}

if ($printVersion) {
    print "braker.pl version $version\n";
    exit(0);
}

if($nocleanup){
    $cleanup = 0;
}

# Define publications to be cited ##############################################
# braker1, braker-whole, aug-cdna, aug-hmm, diamond, blast1, blast2, gm-es, 
# gm-et, gm-ep, gm-fungus, samtools, bamtools, gth, exonerate, spaln, spaln2,
# makehub
my %pubs;
$pubs{'braker1'} = "\nHoff, K. J., Lange, S., Lomsadze, A., Borodovsky, M., & Stanke, M. (2016). BRAKER1: unsupervised RNA-Seq-based genome annotation with GeneMark-ET and AUGUSTUS. Bioinformatics, 32(5), 767-769.\n";
$pubs{'braker-whole'} = "\nHoff, K. J., Lomsadze, A., Borodovsky, M., & Stanke, M. (2019). Whole-genome annotation with BRAKER. In Gene Prediction (pp. 65-95). Humana, New York, NY.\n";
$pubs{'aug-cdna'} = "\nStanke, M., Diekhans, M., Baertsch, R., & Haussler, D. (2008). Using native and syntenically mapped cDNA alignments to improve de novo gene finding. Bioinformatics, 24(5), 637-644.\n";
$pubs{'aug-hmm'} = "\nStanke, M., Schöffmann, O., Morgenstern, B., & Waack, S. (2006). Gene prediction in eukaryotes with a generalized hidden Markov model that uses hints from external sources. BMC Bioinformatics, 7(1), 62.\n";
$pubs{'diamond'} = "\nBuchfink, B., Xie, C., & Huson, D. H. (2015). Fast and sensitive protein alignment using DIAMOND. Nature Methods, 12(1), 59.\n";
$pubs{'blast1'} = "\nAltschul, S. F., Gish, W., Miller, W., Myers, E. W., & Lipman, D. J. (1990). Basic local alignment search tool. Journal of Molecular Biology, 215(3), 403-410.\n";
$pubs{'blast2'} = "\nCamacho, C., Coulouris, G., Avagyan, V., Ma, N., Papadopoulos, J., Bealer, K., & Madden, T. L. (2009). BLAST+: architecture and applications. BMC Bioinformatics, 10(1), 421.\n";
$pubs{'gm-es'} = "\nLomsadze, A., Ter-Hovhannisyan, V., Chernoff, Y. O., & Borodovsky, M. (2005). Gene identification in novel eukaryotic genomes by self-training algorithm. Nucleic acids research, 33(20), 6494-6506.\n";
$pubs{'gm-et'} = "\nLomsadze, A., Burns, P. D., & Borodovsky, M. (2014). Integration of mapped RNA-Seq reads into automatic training of eukaryotic gene finding algorithm. Nucleic acids research, 42(15), e119-e119.\n";
$pubs{'gm-ep'} = "\nBruna, T., Lomsadze, A., & Borodovsky, M. (2020). GeneMark-EP and-EP+: automatic eukaryotic gene prediction supported by spliced aligned proteins. bioRxiv, 2019-12.\n";
$pubs{'gm-fungus'} = "\nTer-Hovhannisyan, V., Lomsadze, A., Chernoff, Y. O., & Borodovsky, M. (2008). Gene prediction in novel fungal genomes using an ab initio algorithm with unsupervised training. Genome research, 18(12), 1979-1990.\n";
$pubs{'samtools'} = "\nLi, H., Handsaker, B., Wysoker, A., Fennell, T., Ruan, J., Homer, N., ... & Durbin, R. (2009). The sequence alignment/map format and SAMtools. Bioinformatics, 25(16), 2078-2079.\n";
$pubs{'bamtools'} = "\nBarnett, D. W., Garrison, E. K., Quinlan, A. R., Strömberg, M. P., & Marth, G. T. (2011). BamTools: a C++ API and toolkit for analyzing and managing BAM files. Bioinformatics, 27(12), 1691-1692.\n";
$pubs{'gth'} = "\nGremme, G. (2013). Computational gene structure prediction.\n";
$pubs{'spaln'} = "\nGotoh, O. (2008). A space-efficient and accurate method for mapping and aligning cDNA sequences onto genomic sequence. Nucleic acids research, 36(8), 2630-2638.\n";
$pubs{'spaln2'} = "\nIwata, H., & Gotoh, O. (2012). Benchmarking spliced alignment programs including Spaln2, an extended version of Spaln that incorporates additional species-specific features. Nucleic acids research, 40(20), e161-e161.\n";
$pubs{'exonerate'} = "\nSlater, G. S. C., & Birney, E. (2005). Automated generation of heuristics for biological sequence comparison. BMC bioinformatics, 6(1), 31.\n";

# Make paths to input files absolute ###########################################

make_paths_absolute();

# Set working directory ########################################################

my $wdGiven;
# if no working directory is set, use current directory
if ( !defined $workDir ) {;

    ;
    $wdGiven = 0;
    $workDir = $currentDir;
}else {
    $wdGiven = 1;
    my $last_char = substr( $workDir, -1 );
    if ( $last_char eq "\/" ) {
        chop($workDir);
    }
    my $tmp_dir_name = abs_path($workDir);
    $workDir = $tmp_dir_name;
    if ( not( -d $workDir ) ) {
        $prtStr = "\# " . (localtime) . ": Creating directory $workDir.\n";
        $logString .= $prtStr if ( $v > 2 );
        mkdir($workDir) or die ("ERROR: in file " . __FILE__ ." at line "
            . __LINE__ ."\nFailed to create directory $workDir!\n");
    }
}

# check the write permission of $workDir #######################################
if ( !-w $workDir ) {
    $prtStr
        = "\# "
        . (localtime)
        . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
        . "Do not have write permission for $workDir.\nPlease"
        . " use command 'chmod' to reset permissions, or specify another working "
        . "directory with option --workingdir=...\n";
    $logString .= $prtStr;
    print STDERR $logString;
    exit(1);
}

# configure which tools BRAKER is going to run #################################
# * use command line argument if given
# * else use environment variable if present
# * else try to guess (might fail)

$prtStr
    = "\# "
    . (localtime)
    . ": Configuring of BRAKER for using external tools...\n";
$logString .= $prtStr if ( $v > 2 );
set_AUGUSTUS_CONFIG_PATH();
set_AUGUSTUS_BIN_PATH();
set_AUGUSTUS_SCRIPTS_PATH();
if ( not($trainFromGth) ) {
    set_GENEMARK_PATH()
        ; # skip setting GeneMark path if no GeneMark training will be performed
} else {
    if ( not ( defined ($gth2traingenes) ) ) {
            $prtStr
            = "#*********\n"
            . "# WARNING: --gth2traingenes was not enabled, will enable this "
            . "flag, now, because no GeneMark training will be performed!\n"
            . "#*********\n";
        $logString .= $prtStr if ( $v > 0 );
        $gth2traingenes = 1;    # enable if no genemark training is performed
    }
}
if( @bam ) {
    set_BAMTOOLS_PATH();
    set_SAMTOOLS_PATH();
}
if (not ($skipAllTraining)){
    set_BLAST_or_DIAMOND_PATH();
}
if ( @prot_seq_files && !$ESmode ){
    set_ALIGNMENT_TOOL_PATH();
}
if ( not ($skipGetAnnoFromFasta) || $makehub || not ($skip_fixing_broken_genes)){
    set_PYTHON3_PATH();
}
if ( $makehub ) {
    set_MAKEHUB_PATH();
}
if( not($skip_fixing_broken_genes)){
    set_CDBTOOLS_PATH();
}

if($checkOnly){
    $prtStr = "\# " . (localtime)
            . ": Exiting braker.pl because it had been started with "
            . "--softwareCheck option. No training or prediction or file format "
            . "check will be performed.\n";
    $logString .= $prtStr;
    print $logString;
    exit(0);
}

# check for known issues that may cause problems with braker.pl ################
check_upfront();

# check whether braker.pl options are set in a compatible way ##################
check_options();

# Starting braker pipeline #####################################################

$logString .= "\#**********************************************************************************\n";
$logString .= "\#                               CREATING DIRECTORY STRUCTURE                       \n";
$logString .= "\#**********************************************************************************\n";

# check whether $rootDir already exists
if ( $wdGiven == 1 ) {
    $rootDir = $workDir;
}
else {
    $rootDir = "$workDir/braker";
}
if ( -d "$rootDir/$species" && !$overwrite && $wdGiven == 0 ) {
    $prtStr
        = "#*********\n"
        . ": WARNING: $rootDir/$species already exists. Braker will use"
        . " existing files, if they are newer than the input files. You can "
        . "choose another working directory with --workingdir=dir or overwrite "
        . "it with --overwrite.\n"
        . "#*********\n";
    $logString .= $prtStr if ( $v > 0 );
}

# create $rootDir
if ( !-d $rootDir ) {
    $prtStr = "\# "
        . (localtime)
        . ": create working directory $rootDir.\n"
        . "mkdir $rootDir\n";
    make_path($rootDir) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to create direcotry $rootDir!\n");
    $logString .= $prtStr if ( $v > 2 );
}

my $genemarkesDir;
# set other directories
if ( $EPmode == 0 && $ETPmode == 0 && $ESmode == 0) {
    $genemarkDir = "$rootDir/GeneMark-ET";
}elsif ( $ETPmode == 1 ) {
    $genemarkDir = "$rootDir/GeneMark-ETP";
    if(@prot_seq_files){
        $genemarkesDir = "$rootDir/GeneMark-ES";
    }
}elsif ($ESmode == 1 ) {
    $genemarkDir = "$rootDir/GeneMark-ES";
} else {
    $genemarkDir = "$rootDir/GeneMark-EP";
    if(@prot_seq_files){
        $genemarkesDir = "$rootDir/GeneMark-ES";
    }
}
$parameterDir  = "$rootDir/species";
$otherfilesDir = "$rootDir";
$errorfilesDir = "$rootDir/errors";

# if esmode, no hintsfile is given, only ab initio predictions possible
if( $ESmode == 1 ) {
    $ab_initio = 1;
}

################################################################################
# check whether genemark.gtf file exists                                       #
# this is not in check_options because it is possible to use a genemark.gtf    #
# file that resides in the working directory genemark folder implicitely with  #
# skipGeneMark options without giving --genemarkgtf, and directories are not   #
# set in check_options, yet.                                                   #
################################################################################

if ($skipGeneMarkET && $EPmode == 0 && $ETPmode == 0 && $ESmode == 0 && 
    not ( $skipAllTraining) && not ( defined($AUGUSTUS_hints_preds) ) ) {
    $prtStr = "\# "
            . (localtime)
            . ": REMARK: The GeneMark-EX step will be skipped.\n";
    $logString .= $prtStr if ( $v > 3 );
    if ( not($trainFromGth) && not($useexisting)) {
        if (    not( -e "$genemarkDir/genemark.gtf" )
            and not( -e rel2abs($geneMarkGtf) ) )
        {
            $prtStr = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "The --skipGeneMark-EX (X = {S, T, P, TP}) option was "
                    . "used, but there is no genemark.gtf file under "
                    . "$genemarkDir and no valid file --geneMarkGtf=... was "
                    . "specified.\n";
            $logString .= $prtStr;
            if ( defined(rel2abs($geneMarkGtf)) ) {
                $prtStr = "       The specified geneMarkGtf=... file was "
                        . rel2abs($geneMarkGtf).". This is not an accessible file.\n";
                $logString .= $prtStr;
            }
            print STDERR $logString;
            exit(1);
        }
    }
} elsif ( $skipGeneMarkEP && $EPmode == 1 && $ETPmode == 0 && $ESmode == 0 
    && not ($skipAllTraining) && not ( defined($AUGUSTUS_hints_preds) ) ) {
    $prtStr = "REMARK: The GeneMark-EP step will be skipped.\n";
    $logString .= $prtStr if ( $v > 3 );
    if (    not( -e "$genemarkDir/genemark.gtf" )
        and not( -e rel2abs($geneMarkGtf) ) )
    {
        $prtStr = "\# " . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "The --skipGeneMark-EP option was used, but there is "
                . "no genemark.gtf file under $genemarkDir and no valid file "
                . "--geneMarkGtf=... was specified.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        if ( defined($geneMarkGtf) ) {
            $prtStr = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "The specified geneMarkGtf=... file was "
                    . rel2abs($geneMarkGtf).". This is not an accessible file.\n";
            $logString .= $prtStr;
            print STDERR $logString;
        }
        exit(1);
    }
} elsif ( $skipGeneMarkETP && $EPmode == 0 && $ETPmode == 1 && $ESmode == 0 
    && not($skipAllTraining) && not ( defined($AUGUSTUS_hints_preds) )){
    $prtStr = "REMARK: The GeneMark-ETP step will be skipped.\n";
    $logString .= $prtStr if ( $v > 3 );
    if (    not( -e "$genemarkDir/genemark.gtf" )
        and not( -e rel2abs($geneMarkGtf) ) )
    {
        $prtStr = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "The --skipGeneMark-ETP option was used, but there is "
                . "no genemark.gtf file under $genemarkDir and no valid file "
                . "--geneMarkGtf=... was specified.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        if ( defined($geneMarkGtf) ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "The specified geneMarkGtf=... file was "
                . rel2abs($geneMarkGtf).". This is not an accessible file.\n";
            $logString .= $prtStr;
            print STDERR $logString;
        }
        exit(1);
    }
} elsif ( $skipGeneMarkES && $EPmode == 0 && $ETPmode == 0 && $ESmode == 1 
    && not($skipAllTraining) && not ( defined($AUGUSTUS_hints_preds) ) ){
    $prtStr = "REMARK: The GeneMark-ES step will be skipped.\n";
    $logString .= $prtStr if ( $v > 3 );
    if (    not( -e "$genemarkDir/genemark.gtf" )
        and not( -e rel2abs($geneMarkGtf) ) )
    {
        $prtStr = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "The --skipGeneMark-ES option was used, but there is "
                . "no genemark.gtf file under $genemarkDir and no valid file "
                . "--geneMarkGtf=... was specified.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        if ( defined($geneMarkGtf) ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "The specified geneMarkGtf=... file was "
                . rel2abs($geneMarkGtf).". This is not an accessible file.\n";
            $logString .= $prtStr;
            print STDERR $logString;
        }
        exit(1);
    }
} elsif ( ( ( $skipGeneMarkEP && not($trainFromGth) && not ( defined($AUGUSTUS_hints_preds) )) || 
    ( $skipGeneMarkETP && not ($trainFromGth)  && not ( defined($AUGUSTUS_hints_preds) )) || 
    ( $skipGeneMarkES && not ($trainFromGth)  && not ( defined($AUGUSTUS_hints_preds) )) ) 
    && not ($skipAllTraining) &&  not ( defined($AUGUSTUS_hints_preds) ) ) {
    $prtStr = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "Option --skipGeneMarkEP/ETP/ES cannot be used when "
            . "BRAKER is started in GeneMark-ET mode.\n";
    $logString .= $prtStr;
    print STDERR $logString;
    exit(1);
}

$logfile = "$otherfilesDir/braker.log";

# create directory $otherfilesDir
if ( !-d $otherfilesDir ) {
    $prtStr = "\# "
        . (localtime)
        . ": create working directory $otherfilesDir.\n"
        . "mkdir $otherfilesDir\n";
    $logString .= $prtStr if ( $v > 2 );
    make_path($otherfilesDir) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to create directory $otherfilesDir!\n");
}

# make paths to reference annotation files absolute if they were given
if(defined($annot)){
    $annot = rel2abs($annot);
}
if(defined($annot_pseudo)){
    $annot_pseudo = rel2abs($annot_pseudo);
}

# open log file
$prtStr = "\# "
        . (localtime)
        . ": Log information is stored in file $logfile\n";
print STDOUT $prtStr;

open( LOG, ">" . $logfile ) or die("ERROR in file " . __FILE__ ." at line "
    . __LINE__ ."\nCannot open file $logfile!\n");
print LOG $logString;

# open cite file
print LOG "\# "
        . (localtime)
        . ": creating file that contains citations for this BRAKER run at "
        . "$otherfilesDir/what-to-cite.txt...\n" if ($v > 2);
open( CITE, ">", "$otherfilesDir/what-to-cite.txt") or die("ERROR in file " . __FILE__ ." at line "
    . __LINE__ ."\n$otherfilesDir/what-to-cite.txt!\n");
print CITE "When publishing results of this BRAKER run, please cite the following sources:\n";
print CITE "------------------------------------------------------------------------------\n";
print CITE $pubs{'braker1'}; $pubs{'braker1'} = "";
print CITE $pubs{'braker-whole'}; $pubs{'braker-whole'} = "";


if ( (!-d $genemarkDir) && ! $trainFromGth) {
    make_path($genemarkDir) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to create direcotry $genemarkDir!\n");
    print LOG "\# "
        . (localtime)
        . ": create working directory $genemarkDir.\n" if ($v > 2);
    print LOG "mkdir $genemarkDir\n" if ($v > 2);
}

if ( defined($genemarkesDir) ) {
    make_path($genemarkesDir) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to create direcotry $genemarkesDir!\n");
    print LOG "\# "
        . (localtime)
        . ": create working directory $genemarkesDir.\n" if ($v > 2);
    print LOG "mkdir $genemarkesDir\n" if ($v > 2);
}

# set gthTrainGenes file
if ( $gth2traingenes ) {
    $gthTrainGeneFile = "$otherfilesDir/gthTrainGenes.gtf";
}

# softlink genemark.gtf file
if ( defined($geneMarkGtf) ) {
    print LOG "\#  "
        . (localtime)
        . ": creating softlink of ".rel2abs($geneMarkGtf)." to "
        . "$genemarkDir/genemark.gtf.\n" if ($v > 2);
    $cmdString =  "ln -s ".rel2abs($geneMarkGtf)." $genemarkDir/genemark.gtf";
    print LOG "$cmdString\n" if ($v > 2);
    system($cmdString) == 0 or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");
}

# softlink genemark_hintsfile.gff
if ( defined($gm_hints) ) {
    print LOG "\#  "
        . (localtime)
        . ": creating softlink of $gm_hints to "
        . "$otherfilesDir/genemark_hintsfile.gff.\n" if ($v > 2);
    $cmdString =  "ln -s ".rel2abs($gm_hints)." $otherfilesDir/genemark_hintsfile.gff";
    print LOG "$cmdString\n" if ($v > 2);
    system($cmdString) == 0 or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");
    # if genemark_hintsfile.gff was specified, it's the restart of a job and --hints was also specified
    # and is expected to have exactly one file, not several, the hintsfile.gff of a previous job
    if( defined ($hints[0]) ) {
        print LOG "\#  "
            . (localtime)
            . ": creating softlink of $hints[0] to "
           . "$otherfilesDir/hintsfile.gff.\n" if ($v > 2);
        $cmdString =  "ln -s ".rel2abs($hints[0])." $otherfilesDir/hintsfile.gff";
        print LOG "$cmdString\n" if ($v > 2);
        system($cmdString) == 0 or die("ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nFailed to execute: $cmdString!\n");
    }else{
        $prtStr = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "The option --genemark_hintsfile=string was specified, but "
                . "the option --hints=string and "
                . "was not given. Both files must be specified "
                . "in order to start a BRAKER run that builds on top hints produced "
                . "in a previous BRAKER run in --etpmode or --epmode!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }
}

# copy evidence.gff file, do not softlink because file might be modified in ETPmode
if ( defined($evidence_hints) ){
    print LOG "\#  "
        . (localtime)
        . ": copying $evidence_hints to "
        . "$otherfilesDir/evidence.gff...\n" if ($v > 2);
    $cmdString =  "cp $evidence_hints $otherfilesDir/evidence.gff";
    print LOG "$cmdString\n" if ($v > 2);
    system($cmdString) == 0 or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");
}

# check whether all required files are specified if genemark_hintsfile.gff is given
if( defined( $gm_hints) ) {
    if( not( defined ( $evidence_hints) ) && not( scalar(@hints) >= 1) ) {
        $prtStr = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "The option --genemark_hintsfile=string was specified, but "
                . "at least one of the options --hints=string(s) and "
                . "--evidence=string were not given. All files must be specified "
                . "in order to start a BRAKER run that builds on top hints produced "
                . "in a previous BRAKER run in --etpmode!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

}

# softlink prothint.gff
if ( defined($prothint_file) ){
        print LOG "\#  "
        . (localtime)
        . ": creating softlink of ".rel2abs($prothint_file)." to "
        . "$otherfilesDir/prothint.gff...\n" if ($v > 2);
    $cmdString =  "ln -s ". rel2abs($prothint_file)." $otherfilesDir/prothint.gff";
    print LOG "$cmdString\n" if ($v > 2);
    system($cmdString) == 0 or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");
}

# create parameter directory
if ( !-d $parameterDir ) {
    make_path($parameterDir) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to create direcotry $parameterDir!\n");
    print LOG "\# "
        . (localtime)
        . ": create working directory $parameterDir\n"
        . "mkdir $parameterDir\n" if ($v > 2);
}

# create error file directory
if ( !-d $errorfilesDir ) {
    make_path($errorfilesDir)or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to create direcotry $errorfilesDir!\n");
    print LOG "\# "
        . (localtime)
        . ": create working directory $errorfilesDir\n"
        . "mkdir $errorfilesDir\n" if ($v > 2);
}

# need to do this check after $errorfilesDir has been set:
if (not($skipGetAnnoFromFasta) || $makehub){
    check_biopython();
}

print LOG "\# "
    . (localtime)
    . ": changing into working directory $rootDir\n"
    . "cd $rootDir\n" if ($v > 2);

chdir $rootDir or die("ERROR in file " . __FILE__ ." at line ".
    __LINE__ ."\nCould not change into directory $rootDir.\n");

if ( $skipAllTraining == 0 && not ( defined($AUGUSTUS_hints_preds) ) ) {
    # create new species parameter files; we do this FIRST, before anything else,
    # because if you start several processes in parallel, you might otherwise end
    # up with those processes using the same species directory!
    new_species();
} else {
    # if no training will be executed, check whether species parameter files exist
    my $specPath
        = "$AUGUSTUS_CONFIG_PATH/species/$species/$species" . "_";
    my @confFiles = (
        "exon_probs.pbl",   "igenic_probs.pbl",
        "intron_probs.pbl",
        "parameters.cfg",   "weightmatrix.txt"
    );

    foreach (@confFiles) {
        if ( not( -e "$specPath" . "$_" ) ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Config file $specPath"
                . "$_ for species $species "
                . "does not exist!\n";
            print LOG $prtStr;
            print STDERR $prtStr;
            exit(1);
        }
    }
    if ( $UTR eq "on" && !$AUGUSTUS_hints_preds && !$skipAllTraining ) {
        @confFiles = ( "metapars.utr.cfg", "utr_probs.pbl" );
        foreach (@confFiles) {
            if ( not( -e "$specPath" . "$_" ) ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "Config file $specPath"
                    . "$_ for species $species "
                    . "does not exist!\n";
                print LOG $prtStr;
                print STDERR $prtStr;
                exit(1);
            }
        }
    }elsif( $UTR eq "on" && not(defined($skipAllTraining))) {
        if( not ( -e $specPath . "metapars.utr.cfg" ) ) {
            $prtStr = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "Config file $specPath"
                    . "metapars.utr.cfg for species $species "
                    . "does not exist!\n";
            print LOG $prtStr;
            print STDERR $prtStr;
            exit(1);
        }
    }elsif( $UTR eq "on" && $skipAllTraining==1 ) {
        if( not ( -e $specPath . "utr_probs.pbl" ) ) {
            $prtStr = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "Config file $specPath"
                    . "utr_probs.pbl for species $species "
                    . "does not exist!\n";
            print LOG $prtStr;
            print STDERR $prtStr;
            exit(1);
        }
    }
}

 # check fasta headers
check_fasta_headers($genome, 1);
if (@prot_seq_files) {
    my @tmp_prot_seq;
    foreach (@prot_seq_files) {
        push(@tmp_prot_seq, $_);
        check_fasta_headers($_, 0);
    }
    @prot_seq_files = @tmp_prot_seq;
}

# count scaffold sizes and check whether the assembly is not too fragmented for
#  parallel execution of AUGUSTUS
open (GENOME, "<", "$otherfilesDir/genome.fa") or clean_abort(
    "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting, "ERROR in file "
    . __FILE__ ." at line ". __LINE__
    ."\nCould not open file $otherfilesDir/genome.fa");
my $gLocus;
while( <GENOME> ){
    chomp;
    if(m/^>(.*)/){
        $gLocus = $1;
    }else{
        if(not(defined($scaffSizes{$gLocus}))){
            $scaffSizes{$gLocus} = length ($_);
        }else{
            $scaffSizes{$gLocus} += length ($_);
        }
    }
}
close (GENOME) or clean_abort(
    "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting, "ERROR in file "
    . __FILE__ ." at line ". __LINE__
    . "\nCould not close file $otherfilesDir/genome.fa");
my @nScaffs = keys %scaffSizes;
my $totalScaffSize = 0;
foreach( values %scaffSizes) {
    $totalScaffSize += $_;
}
# unsure what is an appropriate limit, because it depends on the kernel and
# on the stack size. Use 30000 just to be sure. This will result in ~90000 files in the
# augustus_tmp folder.
if ( (scalar(@nScaffs) > 30000) && ($CPU > 1) ) {
    $prtStr = "#*********\n"
            . "# WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "file $genome contains a highly fragmented assembly ("
            . scalar(@nScaffs)." scaffolds). This may lead "
            . "to problems when running AUGUSTUS via braker in parallelized "
            . "mode. You set --cores=$CPU. You should run braker.pl in linear "
            . "mode on such genomes, though (--cores=1).\n"
            . "#*********\n";
    print STDOUT $prtStr;
    print LOG $prtStr;
}elsif( (($totalScaffSize / $chunksize) > 30000) && ($CPU > 1) ){
    $prtStr = "#*********\n"
            . "# WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "file $genome contains contains $totalScaffSize bases. "
            . "This may lead "
            . "to problems when running AUGUSTUS via braker in parallelized "
            . "mode. You set --cores=$CPU. There is a variable \$chunksize in "
            . "braker.pl. Default value is currently $chunksize. You can adapt "
            . "this to a higher number. The total base content / chunksize * 3 "
            . "should not exceed the number of possible arguments for commands "
            . "like ls *, cp *, etc. on your system.\n"
            . "#*********\n";
    print STDOUT $prtStr;
    print LOG $prtStr;
}

# define $genemark_hintsfile: is needed because genemark can only handle intron
# hints in braker.pl, AUGUSTUS can also handle other hints types
$hintsfile          = "$otherfilesDir/hintsfile.gff";
if(! $trainFromGth && ! $ESmode && not ( defined($AUGUSTUS_hints_preds) )) {
    $genemark_hintsfile = "$otherfilesDir/genemark_hintsfile.gff";
}

if($ESmode==0){
    print LOG "\#**********************************************************************************\n"
            . "\#                               PROCESSING HINTS                                   \n"
            . "\#**********************************************************************************\n";
}

# make hints from protein data if EPmode/ETPmode, otherwise from GenomeThreader/Spaln/Exonerate

if( @prot_seq_files && (($EPmode==1) || ($ETPmode==1)) ){
    run_prothint();
}elsif( @prot_seq_files or @prot_aln_files 
    && not ( defined($AUGUSTUS_hints_preds) ) ){
    make_prot_hints(); # not ProtHint, but old pipeline for generating protein hints!
}

# make hints from RNA-Seq
if ( @bam ) {
    make_rnaseq_hints();
}

# add other user supplied hints
if (@hints && not ( defined($AUGUSTUS_hints_preds) ) && not( defined($gm_hints) ) ) {
    add_other_hints();
}

# extract intron hints from hintsfile.gff for GeneMark (in ETP mode also used for AUGUSTUS)

if ( (! $trainFromGth || ($skipAllTraining==1 && $ETPmode==0) ) && ($ESmode == 0)) {
    if (not ( defined($AUGUSTUS_hints_preds) ) && not( defined($gm_hints) ) ){ # this might be questionable, only ok if users provide 
                                                 # the hintsfile from previous run, which they probably 
                                                 # will
       get_genemark_hints();
    }
}


# train gene predictors
if ( $skipAllTraining == 0 && not ( defined($AUGUSTUS_hints_preds) ) ) {
    if ( not($trainFromGth) ) {
        print LOG "\#**********************************************************************************\n"
                . "\#                              RUNNING GENEMARK-EX                                 \n"
                . "\#**********************************************************************************\n";
        if ( $EPmode == 0 && $ETPmode==0 && $ESmode == 0 ) {
            if( not( defined( $geneMarkGtf ) ) ){
                check_genemark_hints();
                GeneMark_ET();    # run GeneMark-ET
            }
            filter_genemark();
        } elsif ( $EPmode == 1 ) {
            # remove reformatting of hintsfile, later!
            # format_ep_hints(); # not required anymore since provided as $prothint_file
            # create_evidence_gff(); # not required anymore since provided as $evidence
            if( not( defined( $geneMarkGtf ) ) ){
                check_genemark_hints();
                GeneMark_EP();
            }
            filter_genemark();
        } elsif ( $ETPmode == 1 ) {
            # format_ep_hints(); # not required anymore since provided as $prothint_file
            if ( not( defined( $geneMarkGtf ) ) ){
                if ( not( defined( $gm_hints ) ) ){
                    create_evidence_gff(); # evidence from both RNA-Seq and proteins
                    append_prothint_to_genemark_hints();
                }
                check_genemark_hints();
                GeneMark_ETP();
            }
            filter_genemark();
        } elsif  ( $ESmode == 1 ) {
            if( not( defined( $geneMarkGtf ) ) ){
                GeneMark_ES($genemarkDir);
            }
            filter_genemark();
        }
    }

    print LOG "\#**********************************************************************************\n"
            . "\#                               TRAIN AUGUSTUS                                     \n"
            . "\#**********************************************************************************\n";
    # train AUGUSTUS
    training_augustus();
}

if ( $skipAllTraining == 1 && ( ($ETPmode == 1) ) ){
    create_evidence_gff(); # otherwise no manual etp hints...
    #check_genemark_hints();
}

if( not ( defined( $AUGUSTUS_hints_preds ) ) ){
    print LOG "\#**********************************************************************************\n"
            . "\#                               PREDICTING GENES WITH AUGUSTUS (NO UTRS)           \n"
            . "\#**********************************************************************************\n";
    augustus("off");    # run augustus without UTR
    merge_transcript_sets("off");
}

if( not ( defined ($skipIterativePrediction) )  && $EPmode == 1 ) {
    print LOG "\#**********************************************************************************\n"
            . "\#              PREDICTING GENES WITH AUGUSTUS (NO UTRS, ITERATION 2)               \n"
            . "\#**********************************************************************************\n";
    move_aug_preds(); # store as *_iter1*
    run_prothint_iter2();
    augustus("off");    # run augustus without UTR with hints from ProtHint iteration 2
    merge_transcript_sets("off");

}

if ( @bam && ( ($UTR eq "on" || defined($AUGUSTUS_hints_preds) ) && not($skipAllTraining) ) ) { # if you give this input, train parameters!
    print LOG "\#**********************************************************************************\n"
            . "\#                               TRAINING AUGUSTUS UTR PARAMETERS                   \n"
            . "\#**********************************************************************************\n";
    train_utr(); # includes bam2wig
} elsif (@bam && $UTR eq "on") {
    if(!@stranded){
        bam2wig();
    }else{
        bam2stranded_wig();
    }
}

if ( $UTR eq "on") {
    if(not @stranded){
        wig2hints(); # convert coverage information to ep hints
    }else{
        stranded_wig2ep_hints();
    }
    print LOG "\#**********************************************************************************\n"
            . "\#                               PREDICTING GENES WITH AUGUSTUS (UTRS)              \n"
            . "\#**********************************************************************************\n";
    augustus("on"); # run augustus with UTR
    merge_transcript_sets("on");
}



if ( $gff3 != 0) {
    all_preds_gtf2gff3();
}

if( $annot ) {
    evaluate();
}

if ( $makehub ) {
    print LOG "\#**********************************************************************************\n"
            . "\#                               GENERATING TRACK DATA HUB                          \n"
            . "\#**********************************************************************************\n";
    make_hub();
}

clean_up();         # delete all empty files
print LOG "\#**********************************************************************************\n"
        . "\#                               BRAKER RUN FINISHED                                \n"
        . "\#**********************************************************************************\n";

close(CITE) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
    ."\nCould not close file $otherfilesDir/what-to-cite.txt!\n");

close(LOG) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
    ."\nCould not close log file $logfile!\n");


############### sub functions ##################################################

####################### make_paths_absolute ####################################
# make paths to all input files absolute
################################################################################

sub make_paths_absolute {

    # make genome path absolute
    $genome    = rel2abs($genome);

    # make bam paths absolute
    if (@bam) {
        @bam = split( /[\s,]/, join( ',', @bam ) );
        for ( my $i = 0; $i < scalar(@bam); $i++ ) {
            $bam[$i] = rel2abs( $bam[$i] );
        }
    }

    # make hints paths absolute
    if (@hints) {
        @hints = split( /[\s,]/, join( ',', @hints ) );
        for ( my $i = 0; $i < scalar(@hints); $i++ ) {
            $hints[$i] = rel2abs( $hints[$i] );
        }
    }

    # make extrinsic file paths absolute
    if (@extrinsicCfgFiles) {
        @extrinsicCfgFiles = split( /[\s,]/, join( ',', @extrinsicCfgFiles ) );
        for ( my $i = 0; $i < scalar(@extrinsicCfgFiles); $i++ ) {
            $extrinsicCfgFiles[$i] = rel2abs ($extrinsicCfgFiles[$i]);
        }
    }

    # make prot seq file paths absolut
    if (@prot_seq_files) {
        @prot_seq_files = split( /[\s,]/, join( ',', @prot_seq_files ) );
        for ( my $i = 0; $i < scalar(@prot_seq_files); $i++ ) {
            $prot_seq_files[$i] = rel2abs( $prot_seq_files[$i] );
        }
    }

    # make prot aln paths absolute
    if (@prot_aln_files) {
        @prot_aln_files = split( /[\s,]/, join( ',', @prot_aln_files ) );
        for ( my $i = 0; $i < scalar(@prot_aln_files); $i++ ) {
            $prot_aln_files[$i] = rel2abs( $prot_aln_files[$i] );
        }
    }

}

####################### set_AUGUSTUS_CONFIG_PATH ###############################
# * set path to AUGUSTUS_CONFIG_PATH
# * this directory contains a folder species and a folder config for running
#   AUGUSTUS
# * ../bin is usually the location of augustus binaries
# * ../scripts is usually the location of augustus scripts
################################################################################

sub set_AUGUSTUS_CONFIG_PATH {

    # get path from ENV (if available)
    if ( defined( $ENV{'AUGUSTUS_CONFIG_PATH'} ) && not(defined($augustus_cfg_path)) ) {
        if ( -e $ENV{'AUGUSTUS_CONFIG_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$AUGUSTUS_CONFIG_PATH. "
                . "Setting \$AUGUSTUS_CONFIG_PATH to "
                . $ENV{'AUGUSTUS_CONFIG_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_CONFIG_PATH = $ENV{'AUGUSTUS_CONFIG_PATH'};
        }
    }
    elsif(not(defined($augustus_cfg_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$AUGUSTUS_CONFIG_PATH "
            . "(either variable does not exist, or the path given in variable "
            . "does not exist). Will try to set this variable in a different "
            . "way, later.\n";
        $logString .= $prtStr if ($v > 1);
    }

    # get path from braker (if available, overwrite ENV retrieved)
    if ( defined($augustus_cfg_path) ) {
        my $last_char = substr( $augustus_cfg_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($augustus_cfg_path);
        }
        if ( -d $augustus_cfg_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Command line flag --AUGUSTUS_CONFIG_PATH was provided."
                . " Setting \$AUGUSTUS_CONFIG_PATH in braker.pl to "
                . "$augustus_cfg_path.\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_CONFIG_PATH = $augustus_cfg_path;
        }
        else {
            $prtStr
                = "#*********\n"
                . ": WARNING: Command line flag --AUGUSTUS_CONFIG_PATH "
                . "was provided. The given path $augustus_cfg_path is not a "
                . "directory. Cannot use this as variable "
                . "\$AUGUSTUS_CONFIG_PATH in braker.pl!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # if no AUGUSTUS config given, try to guess from the "augustus" executable
    if ( not( defined $AUGUSTUS_CONFIG_PATH )
        or length($AUGUSTUS_CONFIG_PATH) == 0 )
    {
        my $epath = which 'augustus';
        if(defined($epath)){
            $AUGUSTUS_CONFIG_PATH = dirname( abs_path($epath) ) . "/../config";
            $augustus_cfg_path    = $AUGUSTUS_CONFIG_PATH;
        }else{
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Tried to find augustus binary with which but failed.\n";
            $logString .= $prtStr;
        }
        if ( not( -d $AUGUSTUS_CONFIG_PATH ) ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Tried guessing \$AUGUSTUS_CONFIG_PATH from "
                . "system augustus path, but $AUGUSTUS_CONFIG_PATH is not a "
                . "directory.\n";
            $logString .= $prtStr;
        }
    }
    my $aug_conf_err;
    $aug_conf_err
        .= "There are 3 alternative ways to set this variable for braker.pl:\n"
        . "   a) provide command-line argument "
        . "--AUGUSTUS_CONFIG_PATH=/your/path\n"
        . "   b) use an existing environment variable \$AUGUSTUS_CONFIG_PATH\n"
        . "      for setting the environment variable, run\n"
        . "           export AUGUSTUS_CONFIG_PATH=/your/path\n"
        . "      in your shell. You may append this to your .bashrc or\n"
        . "      .profile file in order to make the variable available to all\n"
        . "      your bash sessions.\n"
        . "   c) braker.pl can try guessing the location of\n"
        . "      \$AUGUSTUS_CONFIG_PATH from an augustus executable that is\n"
        . "      available in your \$PATH variable.\n"
        . "      If you try to rely on this option, you can check by typing\n"
        . "           which augustus\n"
        . "      in your shell, whether there is an augustus executable in\n"
        . "      your \$PATH\n"
        . "      Be aware: the \$AUGUSTUS_CONFIG_PATH must be writable for\n"
        . "                braker.pl because braker.pl is a pipeline that\n"
        . "                optimizes parameters that reside in that\n"
        . "                directory. This might be problematic in case you\n"
        . "                are using a system-wide installed augustus \n"
        . "                installation that resides in a directory that is\n"
        . "                not writable to you as a user.\n";

    # Give user installation instructions
    if ( not( defined $AUGUSTUS_CONFIG_PATH )
        or length($AUGUSTUS_CONFIG_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "\$AUGUSTUS_CONFIG_PATH is not defined!\n";
        $logString .= $prtStr;
        $logString .= $aug_conf_err if ($v > 0);
        print STDERR $logString;
        exit(1);
    }
    elsif ( not( -w "$AUGUSTUS_CONFIG_PATH/species" ) )
    {    # check whether config path is writable
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "AUGUSTUS_CONFIG_PATH/species (in this case ";
        $prtStr .= "$AUGUSTUS_CONFIG_PATH/$species) is not writeable.\n";
        $logString .= $prtStr;
        $logString .= $aug_conf_err if ($v > 0);
        print STDERR $logString;
        exit(1);
    }

}

####################### set_AUGUSTUS_BIN_PATH ##################################
# * usually AUGUSTUS_CONFIG_PATH/../bin but may differ on some systems
################################################################################

sub set_AUGUSTUS_BIN_PATH {

    # get path from ENV (if available)
    if ( defined( $ENV{'AUGUSTUS_BIN_PATH'} ) && not (defined($augustus_bin_path) ) ) {
        if ( -e $ENV{'AUGUSTUS_BIN_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$AUGUSTUS_BIN_PATH. Setting "
                . "\$AUGUSTUS_BIN_PATH to ". $ENV{'AUGUSTUS_BIN_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_BIN_PATH = $ENV{'AUGUSTUS_BIN_PATH'};
        }
    }
    elsif (not (defined($augustus_bin_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$AUGUSTUS_BIN_PATH "
            . "(either variable does not exist, or the path given in variable "
            . "does not exist). Will try to set this variable in a different "
            . "way, later.\n";
        $logString .= $prtStr if ($v > 1);
    }

    # get path from braker (if available, overwrite ENV retrieved)
    if ( defined($augustus_bin_path) ) {
        my $last_char = substr( $augustus_bin_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($augustus_bin_path);
        }
        if ( -d $augustus_bin_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$AUGUSTUS_BIN_PATH to command line argument ";
            $prtStr .= "--AUGUSTUS_BIN_PATH value $augustus_bin_path.\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_BIN_PATH = $augustus_bin_path;
        }
        else {
            $prtStr
                = "#*********\n"
                . "# WARNING: Command line argument --AUGUSTUS_BIN_PATH was "
                . "supplied but value $augustus_bin_path is not a directory. "
                . "Will not set \$AUGUSTUS_BIN_PATH to $augustus_bin_path!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 1);
        }
    }

    # if both failed, try to guess
    if ( not( defined($AUGUSTUS_BIN_PATH) )
        || length($AUGUSTUS_BIN_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$AUGUSTUS_BIN_PATH from "
            . "\$AUGUSTUS_CONFIG_PATH.\n";
        $logString .= $prtStr if ($v > 1);
        if ( -d "$AUGUSTUS_CONFIG_PATH/../bin" ) {
            $prtStr
                = "\# " . (localtime) . ": Setting \$AUGUSTUS_BIN_PATH to "
                . "$AUGUSTUS_CONFIG_PATH/../bin\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_BIN_PATH = "$AUGUSTUS_CONFIG_PATH/../bin";
        }
        else {
            $prtStr
                = "#*********\n"
                . "# WARNING: Guessing the location of "
                . "\$AUGUSTUS_BIN_PATH failed. $AUGUSTUS_CONFIG_PATH/../bin is "
                . "not a directory!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    if ( not( defined($AUGUSTUS_BIN_PATH) ) ) {
        my $aug_bin_err;
        $aug_bin_err
            .= "There are 3 alternative ways to set this variable for\n"
            .  "braker.pl:\n"
            . "   a) provide command-line argument \n"
            . "      --AUGUSTUS_BIN_PATH=/your/path\n"
            . "   b) use an existing environment variable \$AUGUSTUS_BIN_PATH\n"
            . "      for setting the environment variable, run\n"
            . "           export AUGUSTUS_BIN_PATH=/your/path\n"
            . "      in your shell. You may append this to your .bashrc or\n"
            . "      .profile file in order to make the variable available to\n"
            . "      all your bash sessions.\n"
            . "   c) braker.pl can try guessing the location of \n"
            . "      \$AUGUSTUS_BIN_PATH from the location of \n"
            . "      \$AUGUSTUS_CONFIG_PATH (in this case\n"
            . "      $AUGUSTUS_CONFIG_PATH/../bin\n";
        $prtStr = "\# " . (localtime) . ": ERROR: in file " . __FILE__
            . " at line ". __LINE__ . "\n" . "\$AUGUSTUS_BIN_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $aug_bin_err if ($v > 0);
        print STDERR $logString;
        exit(1);
    }
}

####################### set_AUGUSTUS_SCRIPTS_PATH ##############################
# * usually AUGUSTUS_CONFIG_PATH/../scripts but may differ on some systems
################################################################################

sub set_AUGUSTUS_SCRIPTS_PATH {

    # first try to get path from ENV
    if ( defined( $ENV{'AUGUSTUS_SCRIPTS_PATH'} ) && not(defined($augustus_scripts_path)) ) {
        if ( -e $ENV{'AUGUSTUS_SCRIPTS_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$AUGUSTUS_SCRIPTS_PATH. "
                . "Setting \$AUGUSTUS_SCRIPTS_PATH to "
                . $ENV{'AUGUSTUS_SCRIPTS_PATH'} ."\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_SCRIPTS_PATH = $ENV{'AUGUSTUS_SCRIPTS_PATH'};
        }
    }
    elsif(not(defined($augustus_scripts_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$AUGUSTUS_SCRIPTS_PATH "
            . "(either variable does not exist, or the path given in variable "
            . "does not exist). Will try to set this variable in a different "
            . "way, later.\n";
        $logString .= $prtStr if ($v > 1);
    }

    # then try to get path from braker
    if ( defined($augustus_scripts_path) ) {
        my $last_char = substr( $augustus_scripts_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($augustus_scripts_path);
        }
        if ( -d $augustus_scripts_path ) {
            $AUGUSTUS_SCRIPTS_PATH = $augustus_scripts_path;
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$AUGUSTUS_SCRIPTS_PATH to command line "
                . "argument --AUGUSTUS_SCRIPTS_PATH value "
                . "$augustus_scripts_path.\n";
            $logString .= $prtStr if ($v > 1);
        }
        else {
            $prtStr
                = "#*********\n"
                . "# WARNING: Command line argument --AUGUSTUS_SCRIPTS_PATH "
                . "was supplied but value $augustus_scripts_path is not a "
                . "directory. Will not set \$AUGUSTUS_SCRIPTS_PATH to "
                . "$augustus_scripts_path!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # otherwise try to guess
    if ( not( defined($AUGUSTUS_SCRIPTS_PATH) )
        || length($AUGUSTUS_SCRIPTS_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$AUGUSTUS_SCRIPTS_PATH from "
            . "\$AUGUSTUS_CONFIG_PATH.\n";
        $logString .= $prtStr if ($v > 1);
        if ( -d "$AUGUSTUS_CONFIG_PATH/../scripts" ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$AUGUSTUS_SCRIPTS_PATH to "
                . "$AUGUSTUS_CONFIG_PATH/../scripts\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_SCRIPTS_PATH = "$AUGUSTUS_CONFIG_PATH/../scripts";
        }
        else {
            $prtStr
                = "#*********\n"
                . "# WARNING: Guessing the location of "
                . "\$AUGUSTUS_SCRIPTS_PATH failed. "
                . "$AUGUSTUS_CONFIG_PATH/../scripts is not a "
                . "directory!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }
    if ( not( defined($AUGUSTUS_SCRIPTS_PATH) ) ) {
        my $aug_scr_err;
        $aug_scr_err
            .= "There are 3 alternative ways to set this variable for\n"
            . " braker.pl:\n"
            . "   a) provide command-line argument \n"
            . "      --AUGUSTUS_SCRIPTS_PATH=/your/path\n"
            . "   b) use an existing environment variable \n"
            . "      \$AUGUSTUS_SCRIPTS_PATH for setting the environment \n"
            . "      variable, run\n"
            . "           export AUGUSTUS_SCRIPTS_PATH=/your/path\n"
            . "      in your shell. You may append this to your .bashrc or\n"
            . "      .profile file in order to make the variable available to\n"
            . "      all your bash sessions.\n"
            . "   c) braker.pl can try guessing the location of\n"
            . "      \$AUGUSTUS_SCRIPTS_PATH from the location of\n"
            . "      \$AUGUSTUS_CONFIG_PATH (in this case \n"
            . "      $AUGUSTUS_CONFIG_PATH/../scripts\n";
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "\$AUGUSTUS_SCRIPTS_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $aug_scr_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }
}

####################### set_BAMTOOLS_PATH ######################################
# * set path to bamtools
################################################################################

sub set_BAMTOOLS_PATH {

    # try to get path from ENV
    if ( defined( $ENV{'BAMTOOLS_PATH'} ) && not(defined($bamtools_path))) {
        if ( -e $ENV{'BAMTOOLS_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$BAMTOOLS_PATH. Setting "
                . "\$BAMTOOLS_PATH to ".$ENV{'BAMTOOLS_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $BAMTOOLS_BIN_PATH = $ENV{'BAMTOOLS_PATH'};
        }
    }
    elsif(not(defined($bamtools_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$BAMTOOLS_PATH "
            . "(either variable does not exist, or the path given in "
            . "variable does not exist). Will try to set this variable in a "
            . "different way, later.\n";
        $logString .= $prtStr if ($v > 1);
    }

    # try to get path from braker
    if ( defined($bamtools_path) ) {
        my $last_char = substr( $bamtools_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($bamtools_path);
        }
        if ( -d $bamtools_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$BAMTOOLS_BIN_PATH to command line argument "
                . "--BAMTOOLS_PATH value $bamtools_path.\n";
            $logString .= $prtStr if ($v > 1);
            $BAMTOOLS_BIN_PATH = $bamtools_path;
        }
        else {
            $prtStr
                = "#*********\n"
                . "# WARNING: Command line argument --BAMTOOLS_PATH was "
                . "supplied but value $bamtools_path is not a directory. Will "
                . "not set \$BAMTOOLS_BIN_PATH to $bamtools_path!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # try to guess
    if ( not( defined($BAMTOOLS_BIN_PATH) )
        || length($BAMTOOLS_BIN_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$BAMTOOLS_BIN_PATH from location of bamtools"
            . " executable that is available in your \$PATH\n";
        $logString .= $prtStr if ($v > 1);
        my $epath = which 'bamtools';
        if(defined($epath)){
            if ( -d dirname($epath) ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$BAMTOOLS_BIN_PATH to "
                    . dirname($epath) . "\n";
                $logString .= $prtStr if ($v > 1);
                $BAMTOOLS_BIN_PATH = dirname($epath);
            }
        }
        else {
            $prtStr
                = "#*********\n"
                . "WARNING: Guessing the location of \$BAMTOOLS_BIN_PATH "
                . "failed.\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    if ( not( defined($BAMTOOLS_BIN_PATH) ) ) {
        my $bamtools_err;
        $bamtools_err
            .= "There are 3 alternative ways to set this variable for\n"
            . " braker.pl:\n"
            . "   a) provide command-line argument --BAMTOOLS_PATH=/your/path\n"
            . "   b) use an existing environment variable \$BAMTOOLS_PATH\n"
            . "      for setting the environment variable, run\n"
            . "           export BAMTOOLS_PATH=/your/path\n"
            . "      in your shell. You may append this to your .bashrc or\n"
            . "      .profile file in order to make the variable available to\n"
            . "      all your bash sessions.\n"
            . "   c) braker.pl can try guessing the location of\n"
            . "      \$BAMTOOLS_BIN_PATH from the location of a bamtools\n"
            . "      executable that is available in your \$PATH variable.\n"
            . "      If you try to rely on this option, you can check by\n"
            . "      typing\n"
            . "           which bamtools\n"
            . "      in your shell, whether there is a bamtools executable in\n"
            . "      your \$PATH\n";
        $prtStr
            = "\# " . (localtime) . " ERROR: in file " . __FILE__ ." at line "
            . __LINE__ . "\n" . "\$BAMTOOLS_BIN_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $bamtools_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }
}

####################### set_GENEMARK_PATH ######################################
# * set path to gmes_petap.pl
# * be aware that GeneMark requires a valid license key file, usually placed
#   home directory as invisible file .gm_key
################################################################################

sub set_GENEMARK_PATH {

    # try to get path from ENV
    if ( defined( $ENV{'GENEMARK_PATH'} ) && not (defined($GMET_path))) {
        if ( -e $ENV{'GENEMARK_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$GENEMARK_PATH. Setting "
                . "\$GENEMARK_PATH to ".$ENV{'GENEMARK_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $GENEMARK_PATH = $ENV{'GENEMARK_PATH'}
                ;    # path to 'gmes_petap.pl' script on system
        }
    }
    elsif(not(defined($GMET_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$GENEMARK_PATH  (either"
            . " variable does not exist, or the path given in variable does "
            . "not exist). Will try to set this variable in a different way, "
            . "later.\n";
        $logString .= $prtStr if ($v > 1);
    }

    # try get path from braker
    if ( defined($GMET_path) ) {
        my $last_char = substr( $GMET_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($GMET_path);
        }
        if ( -d $GMET_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$GENEMARK_PATH to command line argument -"
                . "-GENEMARK_PATH value $GMET_path.\n";
            $logString .= $prtStr if ($v > 1);
            $GENEMARK_PATH = $GMET_path;
        }
        else {
            $prtStr
                = "#*********\n"
                . "# WARNING: Command line argument --GENEMARK_PATH was "
                . "supplied but value $GMET_path is not a directory. Will not "
                . "set \$GENEMARK_PATH to $GMET_path!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # try to guess
    if ( not( defined($GENEMARK_PATH) ) || length($GENEMARK_PATH) == 0 ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$GENEMARK_PATH from location of "
            . "gmes_petap.pl executable that is available in your \$PATH\n";
        $logString .= $prtStr if ($v > 1);
        my $epath = which 'gmes_petap.pl';
        if(defined($epath)){
            if ( -d dirname($epath) ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$GENEMARK_PATH to "
                    . dirname($epath) . "\n";
                $logString .= $prtStr if ($v > 1);
                $GENEMARK_PATH = dirname($epath);
            }
        } else {
            $prtStr = "#*********\n"
                    . "# WARNING: Guessing the location of \$GENEMARK_PATH "
                    . "failed.\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    if ( not( defined($GENEMARK_PATH) )) {
        my $gm_err;
        $gm_err
            .= "There are 3 alternative ways to set this variable for\n"
            . "braker.pl:\n"
            . "   a) provide command-line argument --GENEMARK_PATH=/your/path\n"
            . "   b) use an existing environment variable \$GENEMARK_PATH\n"
            . "      for setting the environment variable, run\n"
            . "           export GENEMARK_PATH=/your/path\n"
            . "      in your shell. You may append this to your .bashrc or \n"
            . "      .profile file in order to make the variable available to\n"
            . "      all your bash sessions.\n"
            . "   c) braker.pl can try guessing the location of \n"
            . "      \$GENEMARK_PATH from the location of a gmes_petap.pl\n"
            . "      executable that is available in your \$PATH variable.\n"
            . "      If you try to rely on this option, you can check by\n"
            . "      typing\n"
            . "           which gmes_petap.pl\n"
            . "      in your shell, whether there is a bamtools executable in\n"
            . "      your \$PATH\n";
        $prtStr = "\# " . (localtime) . ": ERROR: in file " . __FILE__
                . " at line ". __LINE__ ."\n\$GENEMARK_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $gm_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }
}

####################### set_SAMTOOLS_PATH ######################################
# * set path to samtools
#   (used for fixing broken bam headers if possible)
################################################################################

sub set_SAMTOOLS_PATH {

    # try to get from ENV
    if ( defined( $ENV{'SAMTOOLS_PATH'} ) && not (defined($SAMTOOLS_PATH_OP)) ) {
        if ( -e $ENV{'SAMTOOLS_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$SAMTOOLS_PATH. Setting "
                . "\$SAMTOOLS_PATH to ".$ENV{'SAMTOOLS_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $SAMTOOLS_PATH
                = $ENV{'SAMTOOLS_PATH'};    # samtools environment variable
        }
    }
    elsif( not(defined($SAMTOOLS_PATH_OP)) ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$SAMTOOLS_PATH  (either"
            . " variable does not exist, or the path given in variable does"
            . "not exist). Will try to set this variable in a different way, "
            . "later.\n";
        $logString .= $prtStr if ($v > 1);
    }

    # try to get from BRAKER
    if ( defined($SAMTOOLS_PATH_OP) ) {
        my $last_char = substr( $SAMTOOLS_PATH_OP, -1 );
        if ( $last_char eq "\/" ) {
            chop($SAMTOOLS_PATH_OP);
        }
        if ( -d $SAMTOOLS_PATH_OP ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$SAMTOOLS_PATH to command line argument "
                . "--SAMTOOLS_PATH value $SAMTOOLS_PATH_OP.\n";
            $logString .= $prtStr if ($v > 1);
            $SAMTOOLS_PATH = $SAMTOOLS_PATH_OP;
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Command line argument --SAMTOOLS_PATH was supplied "
                    . "but value $SAMTOOLS_PATH_OP is not a directory. Will not "
                    . "set \$SAMTOOLS_PATH to $SAMTOOLS_PATH_OP!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # try to guess
    if ( not( defined($SAMTOOLS_PATH) ) || length($SAMTOOLS_PATH) == 0 ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$SAMTOOLS_PATH from location of samtools "
            . "executable in your \$PATH\n";
        $logString .= $prtStr if ($v > 1);
        my $epath = which 'samtools';
        if(defined($epath)){
            if ( -d dirname($epath) ) {
                  $prtStr
                        = "\# "
                        . (localtime)
                        . ": Setting \$SAMTOOLS_PATH to "
                        . dirname($epath) . "\n";
                        $logString .= $prtStr if ($v > 1);
                        $SAMTOOLS_PATH = dirname($epath);
            }
        }
        else {
            $prtStr
                = "#*********\n"
                . "# WARNING: Guessing the location of \$SAMTOOLS_PATH "
                . "failed / BRAKER failed "
                . "to guess the location of samtools with \"which samtools\"!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    if ( not( defined($SAMTOOLS_PATH) ) ) {
        my $samtools_err;
        $samtools_err
            .= "Samtools is not strictly required for running braker.pl. It\n"
            . "is a optional tool. In case bam files are not formatted \n"
            . "entirely correctly, braker.pl can try fixing certain issues,\n"
            . "automatically, if samtools are available.\n"
            . "There are 3 alternative ways to set this variable for\n"
            . "braker.pl:\n"
            . "   a) provide command-line argument --SAMTOOLS_PATH=/your/path\n"
            . "   b) use an existing environment variable \$SAMTOOLS_PATH\n"
            . "      for setting the environment variable, run\n"
            . "           export SAMTOOLS_PATH=/your/path\n"
            . "      in your shell. You may append this to your .bashrc or\n"
            . "      .profile file in order to make the variable available to\n"
            . "      all your bash sessions.\n"
            . "   c) braker.pl can try guessing the location of \n"
            . "      \$SAMTOOLS_PATH from the location a samtools executable\n"
            . "      that is available in your \$PATH variable.\n"
            . "      If you try to rely on this option, you can check by\n"
            . "      typing\n"
            . "           which samtools\n"
            . "      in your shell, whether there is a samtools executable in\n"
            . "      your \$PATH\n";
        $prtStr = "#*********\n"
                . "#WARNING: \$SAMTOOLS_PATH not set!\n"
                . "#*********\n";
        $logString .= $prtStr;
        $logString .= $samtools_err if ($v > 1);
        print STDERR $logString;
    }
}

####################### set_ALIGNMENT_TOOL_PATH ################################
# * set path to protein alignment tool (GenomeThreader, Spaln or Exonerate)
################################################################################

sub set_ALIGNMENT_TOOL_PATH {
    if (@prot_seq_files) {

        # try go get from ENV
        if ( defined( $ENV{'ALIGNMENT_TOOL_PATH'} ) && not (defined( $ALIGNMENT_TOOL_PATH_OP ) ) ) {
            if ( -e $ENV{'ALIGNMENT_TOOL_PATH'} ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Found environment variable \$ALIGNMENT_TOOL_PATH. "
                    . "Setting \$ALIGNMENT_TOOL_PATH to "
                    . $ENV{'ALIGNMENT_TOOL_PATH'}."\n";
                $logString .= $prtStr if ($v > 1);
                $ALIGNMENT_TOOL_PATH = $ENV{'ALIGNMENT_TOOL_PATH'};
            }
        }
        elsif(not(defined($ALIGNMENT_TOOL_PATH_OP))) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Did not find environment variable \$ALIGNMENT_TOOL_PATH "
                . "(either variable does not exist, or the path given in "
                . "variable does not exist). Will try to set this variable in "
                . "a different way, later.\n";
            $logString .= $prtStr if ($v > 1);
        }

        # try to get from BRAKER
        if ( defined($ALIGNMENT_TOOL_PATH_OP) ) {
            my $last_char = substr( $ALIGNMENT_TOOL_PATH_OP, -1 );
            if ( $last_char eq "\/" ) {
                chop($ALIGNMENT_TOOL_PATH_OP);
            }
            if ( -d $ALIGNMENT_TOOL_PATH_OP ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$ALIGNMENT_TOOL_PATH to command line "
                    . "argument --ALIGNMENT_TOOL_PATH value "
                    . "$ALIGNMENT_TOOL_PATH_OP.\n";
                $logString .= $prtStr if ($v > 1);
                $ALIGNMENT_TOOL_PATH = $ALIGNMENT_TOOL_PATH_OP;
            }
        }
        if ( not( defined($ALIGNMENT_TOOL_PATH) ) || length($ALIGNMENT_TOOL_PATH) == 0 ) {
            if ( defined($prg) ) {
                if ( $prg eq "gth" ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": Trying to guess \$ALIGNMENT_TOOL_PATH from "
                        . "location of GenomeThreader executable in your "
                        . "\$PATH\n";
                    $logString .= $prtStr if ($v > 1);
                    my $epath = which 'gth';
                    if( defined($epath) ) {
                        if ( -d dirname($epath) ) {
                            $prtStr
                                = "\# "
                                . (localtime)
                                . ": Setting \$ALIGNMENT_TOOL_PATH to "
                                . dirname($epath) . "\n";
                            $logString .= $prtStr if ($v > 1);
                            $ALIGNMENT_TOOL_PATH = dirname($epath);
                        }
                    }
                    else {
                        $prtStr = "#*********\n"
                                . "# WARNING: Guessing the location of "
                                . "\$ALIGNMENT_TOOL_PATH failed / BRAKER failed to guess the "
                                . "location of alignment tool with "
                                . "\"which gth\"!\n"
                                . "#*********\n";
                        $logString .= $prtStr if ($v > 0);
                    }
                } elsif ( $prg eq "exonerate" ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": Trying to guess \$ALIGNMENT_TOOL_PATH from "
                        . "location of Exonerate executable in your \$PATH\n";
                    $logString .= $prtStr if ($v > 1);
                    my $epath = which 'exonerate';
                    if(defined($epath)){
                        if ( -d dirname($epath) ) {
                            $prtStr
                                = "\# "
                                . (localtime)
                                . ": Setting \$ALIGNMENT_TOOL_PATH to "
                                . dirname($epath) . "\n";
                            $logString .= $prtStr if ($v > 1);
                            $ALIGNMENT_TOOL_PATH = dirname($epath);
                        }
                    }
                    else {
                        $prtStr = "#*********\n"
                                . "# WARNING: Guessing the location of "
                                . "\$ALIGNMENT_TOOL_PATH failed / BRAKER failed to guess the "
                                . "location of alignment tool with "
                                . "\"which exonerate\"!\n"
                                . "#*********\n";
                        $logString .= $prtStr if ($v > 0);
                    }
                } elsif ( $prg eq "spaln" ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": Trying to guess \$ALIGNMENT_TOOL_PATH "
                        . "from location of Spaln executable in your \$PATH\n";
                    $logString .= $prtStr if ($v > 1);
                    my $epath = which 'spaln';
                    if(defined($epath)){
                        if ( -d dirname($epath) ) {
                            $prtStr
                                = "\# "
                                . (localtime)
                                . ": Setting \$ALIGNMENT_TOOL_PATH to "
                                . dirname($epath) . "\n";
                            $logString .= $prtStr if ($v > 1);
                            $ALIGNMENT_TOOL_PATH = dirname($epath);
                        }
                    }
                    else {
                        $prtStr = "#*********\n"
                                . "# WARNING: Guessing the location of "
                                . "\$ALIGNMENT_TOOL_PATH failed / BRAKER failed to "
                                . "guess the location of alignment tool with "
                                . "\"which spaln\"!\n"
                                . "#*********\n";
                        $logString .= $prtStr if ($v > 0);
                    }
                } elsif ( $prg eq "ph") {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": Trying to guess \$ALIGNMENT_TOOL_PATH "
                        . "from location of ProtHint executable in your \$PATH\n";
                    $logString .= $prtStr if ($v > 1);
                    my $epath = which 'prothint.py';
                    if(defined($epath)){
                        if ( -d dirname($epath) ) {
                            $prtStr
                                = "\# "
                                . (localtime)
                                . ": Setting \$ALIGNMENT_TOOL_PATH to "
                                . dirname($epath) . "\n";
                            $logString .= $prtStr if ($v > 1);
                            $ALIGNMENT_TOOL_PATH = dirname($epath);
                        }
                    }
                    else {
                        $prtStr = "#*********\n"
                                . "# WARNING: Guessing the location of "
                                . "\$ALIGNMENT_TOOL_PATH failed / BRAKER failed to "
                                . "guess the location of alignment tool with "
                                . "\"which prothint.py\"!\n"
                                . "#*********\n";
                        $logString .= $prtStr if ($v > 0);
                    }

                }
                # ProtHint also requires DIAMOND and Spaln, but apparently it brings binaries along
            }
        }

        if ( not( defined($ALIGNMENT_TOOL_PATH) ) ) {
            my $aln_err_str;
            $aln_err_str
                .= "There are 3 alternative ways to set this variable for\n"
                . " braker.pl:\n"
                . "   a) provide command-line argument\n"
                . "      --ALIGNMENT_TOOL_PATH=/your/path\n"
                . "   b) use an existing environment variable\n"
                . "      \$ALIGNMENT_TOOL_PATH for setting the environment\n"
                . "      variable, run\n"
                . "           export ALIGNMENT_TOOL_PATH=/your/path\n"
                . "      in your shell. You may append this to your .bashrc\n"
                . "      or .profile file in order to make the variable\n"
                . "      available to all your bash sessions.\n"
                . "   c) braker.pl can try guessing the location of\n"
                . "      \$ALIGNMENT_TOOL_PATH from the location an alignment\n"
                . "      tool executable (corresponding to the alignment tool\n"
                . "      given by command line argument --prg=yourTool (in\n"
                . "      this case $prg) that is available in your \$PATH\n"
                . "      variable.\n"
                . "      If you try to rely on this option, you can check by\n"
                . "      typing\n"
                . "           which gth\n"
                . "               or\n"
                . "           which exonerate\n"
                . "               or\n"
                . "           which spaln\n"
                . "      in your shell, whether there is an alignment tool\n"
                . "      executable in your \$PATH\n";
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "\$ALIGNMENT_TOOL_PATH not set!\n";
            $logString .= $prtStr;
            $prtStr
                = "This is an obligatory argument if you provided protein "
                . "sequence file(s).\n";
            $logString .= $prtStr;
            $logString .= $aln_err_str if ($v > 1);
            print STDERR $logString;
            exit(1);
        }
    }
}

####################### set_BLAST_or_DIAMOND_PATH ##############################
# * set path to diamond (preferred) or to blastp and formatdb
################################################################################

sub set_BLAST_or_DIAMOND_PATH {
    # first try to set DIAMOND_PATH because that is much faster

    if(not(defined($blast_path))){ # unless blast_path is given explicitely on command line
        # try to get path from ENV
        if ( defined( $ENV{'DIAMOND_PATH'} ) && not (defined($diamond_path)) ) {
            if ( -e $ENV{'DIAMOND_PATH'} ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Found environment variable \$DIAMOND_PATH. Setting "
                    . "\$DIAMOND_PATH to ".$ENV{'DIAMOND_PATH'}."\n";
                $logString .= $prtStr if ($v > 1);
                $DIAMOND_PATH = $ENV{'DIAMOND_PATH'};
            }
        }
        elsif(not(defined($diamond_path))) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Did not find environment variable \$DIAMOND_PATH\n";
            $logString .= $prtStr if ($v > 1);
        }

        # try to get path from command line
        if ( defined($diamond_path) ) {
            my $last_char = substr( $diamond_path, -1 );
            if ( $last_char eq "\/" ) {
                chop($diamond_path);
            }
            if ( -d $diamond_path ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$DIAMOND_PATH to command line argument "
                    . "--DIAMOND_PATH value $diamond_path.\n";
                $logString .= $prtStr if ($v > 1);
                $DIAMOND_PATH = $diamond_path;
            }
            else {
                $prtStr = "#*********\n"
                        . "# WARNING: Command line argument --DIAMOND_PATH was "
                        . "supplied but value $diamond_path is not a directory. Will not "
                        . "set \$DIAMOND_PATH to $diamond_path!\n"
                        . "#*********\n";
                $logString .= $prtStr if ($v > 0);
            }
        }

        # try to guess
        if ( not( defined($DIAMOND_PATH) )
            || length($DIAMOND_PATH) == 0 )
        {
            $prtStr
                = "\# "
                . (localtime)
                . ": Trying to guess \$DIAMOND_PATH from location of diamond"
                . " executable that is available in your \$PATH\n";
            $logString .= $prtStr if ($v > 1);
            my $epath = which 'diamond';
            if(defined($epath)){
                if ( -d dirname($epath) ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": Setting \$DIAMOND_PATH to "
                        . dirname($epath) . "\n";
                    $logString .= $prtStr if ($v > 1);
                    $DIAMOND_PATH = dirname($epath);
                }
            }
            else {
                $prtStr = "#*********\n"
                        . "# WARNING: Guessing the location of \$DIAMOND_PATH "
                        . "failed / BRAKER failed "
                        . " to detect a diamond binary with \"which diamond\"!\n"
                        . "#*********\n";
                $logString .= $prtStr if ($v > 0);
            }
        }
    }

    if(not(defined($DIAMOND_PATH))){
        # try to get path from ENV
        if ( defined( $ENV{'BLAST_PATH'} ) && not (defined($blast_path)) ) {
            if ( -e $ENV{'BLAST_PATH'} ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Found environment variable \$BLAST_PATH. Setting "
                    . "\$BLAST_PATH to ".$ENV{'BLAST_PATH'}."\n";
                $logString .= $prtStr if ($v > 1);
                $BLAST_PATH = $ENV{'BLAST_PATH'};
            }
        }
        elsif(not(defined($blast_path))) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Did not find environment variable \$BLAST_PATH\n";
            $logString .= $prtStr if ($v > 1);
        }
    }

    # try to get path from command line, overrule $DIAMOND_PATH
    if ( defined($blast_path) ) {
        my $last_char = substr( $blast_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($blast_path);
        }
        if ( -d $blast_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$BLAST_PATH to command line argument "
                . "--BLAST_PATH value $blast_path.\n";
            $logString .= $prtStr if ($v > 1);
            $BLAST_PATH = $blast_path;
        }
        else {
            $prtStr = "#*********\n"
                    . ": WARNING: Command line argument --BLAST_PATH was "
                    . "supplied but value $blast_path is not a directory. Will not "
                    . "set \$BLAST_PATH to $blast_path!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # try to guess
    if(not(defined($DIAMOND_PATH))){
        if ( not( defined($BLAST_PATH) )
            || length($BLAST_PATH) == 0 )
        {
            $prtStr
                = "\# "
                . (localtime)
                . ": Trying to guess \$BLAST_PATH from location of blastp"
                . " executable that is available in your \$PATH\n";
            $logString .= $prtStr if ($v > 1);
            my $epath = which 'blastp';
            if(defined($epath)){
                if ( -d dirname($epath) ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": Setting \$BLAST_PATH to "
                        . dirname($epath) . "\n";
                    $logString .= $prtStr if ($v > 1);
                    $BLAST_PATH = dirname($epath);
                }
            }
            else {
                $prtStr = "#*********\n"
                        . "# WARNING: Guessing the location of \$BLAST_PATH "
                        . "failed / BRAKER failed to "
                        . " detect BLAST with \"which blastp\"!\n"
                        . "#*********\n";
                $logString .= $prtStr if ($v > 0);
            }
        }
    }

    if ( not( defined($BLAST_PATH) ) && not ( defined($DIAMOND_PATH)) ) {
        my $blast_err;
        $blast_err .= "aa2nonred.pl can be exectued either with DIAMOND\n"
                   .  "or with BLAST (much slower than DIAMOND). We recommend\n"
                   .  "using DIAMOND.\n"
                   .  "There are 6 different ways to set one of the required\n"
                   .  "variables \$DIAMOND_PATH or \$BLAST_PATH. Please be\n"
                   .  "aware that you need to set only one of them, not both!\n"
                   .  "   a) provide command-line argument\n"
                   .  "      --DIAMOND_PATH=/your/path\n"
                   .  "   b) use an existing environment variable\n"
                   . "       \$DIAMOND_PATH\n"
                   .  "      for setting the environment variable, run\n"
                   .  "           export DIAMOND_PATH=/your/path\n"
                   .  "      in your shell. You may append this to your "
                   .  ".bashrc or .profile file in\n"
                   .  "      order to make the variable available to all your\n"
                   .  "      bash sessions.\n"
                   .  "   c) aa2nonred.pl can try guessing the location of\n"
                   .  "      \$DIAMOND_PATH from the location of a diamond\n"
                   .  "      executable that is available in your \$PATH\n"
                   .  "      variable. If you try to rely on this option, you\n"
                   . "       can check by typing\n"
                   .  "           which diamond\n"
                   .  "      in your shell, whether there is a diamond\n"
                   .  "      executable in your \$PATH\n"
                   .  "   d) provide command-line argument\n"
                   .  "      --BLAST_PATH=/your/path\n"
                   .  "      This will enforce the usage of BLAST in case you"
                   .  "      have installed both BLAST and DIAMOND\n"
                   .  "   e) use an existing environment variable\n"
                   . "       \$BLAST_PATH\n"
                   .  "      for setting the environment variable, run\n"
                   .  "           export BLAST_PATH=/your/path\n"
                   .  "      in your shell. You may append this to your "
                   .  ".bashrc or .profile file in\n"
                   .  "      order to make the variable available to all your\n"
                   .  "      bash sessions.\n"
                   .  "      BRAKER will only check for this variable if it was\n"
                   .  "      previously unable to set a \$DIAMOND_PATH.\n"
                   .  "   f) aa2nonred.pl can try guessing the location of\n"
                   .  "      \$BLAST_PATH from the location of a blastp\n"
                   .  "      executable that is available in your \$PATH\n"
                   .  "      variable. If you try to rely on this option, you\n"
                   .  "      can check by typing\n"
                   .  "           which blastp\n"
                   .  "      in your shell, whether there is a blastp\n"
                   .  "      executable in your \$PATH\n"
                   .  "      BRAKER will only try this if it did not find diamond.\n";
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            . " at line ". __LINE__ . "\n" . "\$BLAST_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $blast_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }

    if(defined($DIAMOND_PATH) and not(defined($blast_path))){
        if ( not ( -x "$DIAMOND_PATH/diamond" ) ) {
            $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
                ." at line ". __LINE__ ."\n"
                . "$DIAMOND_PATH/diamond is not an executable file!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }else{
        if ( not ( -x "$BLAST_PATH/blastp" ) ) {
            $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
                ." at line ". __LINE__ ."\n"
                . "$BLAST_PATH/blastp is not an executable file!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }elsif( not ( -x "$BLAST_PATH/makeblastdb" ) ){
            $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
                . " at line ". __LINE__ ."\n"
                . "$BLAST_PATH/makeblastdb is not an executable file!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }
}

####################### check_biopython ########################################
# check whether biopython and python module re are available
# (for getAnnoFastaFromJoingenes.py)
################################################################################

sub check_biopython{
    my $missingPython3Module = 0;
    $errorfile = $errorfilesDir."/find_python3_re.err";
    $cmdString = "$PYTHON3_PATH/python3 -c \'import re\' 1> /dev/null 2> "
               . "$errorfile";
    if (system($cmdString) != 0) {
        $prtStr = "#*********\n"
                . "# WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Could not find python3 module re:\n";
        open(PYERR, "<", $errorfile) or die ("\# " . (localtime) 
            . " ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\n"
            . "Could not open file $errorfile!\n");
        while(<PYERR>){
            $prtStr .= $_;
        }
        close(PYERR) or die ("\# " . (localtime) . " ERROR: in file " 
            . __FILE__
            ." at line ". __LINE__ ."\n"
            . "Could not close file $errorfile!\n");
        $prtStr .= "#*********\n";
        $logString .= $prtStr;
        $missingPython3Module = 1;
    }
    $errorfile = $errorfilesDir."/find_python3_biopython.err";
    $cmdString = "$PYTHON3_PATH/python3 -c \'from Bio.Seq import Seq\' 1> /dev/null "
               . "2> $errorfile";
    if (system($cmdString) != 0) {
        $prtStr = "#*********\n"
                . "# WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Could not find python3 module biopython:\n";
        open(PYERR, "<", $errorfile) or die ("\# " . (localtime) 
            . " ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\n"
            . "Could not open file $errorfile!\n");
        while(<PYERR>){
            $prtStr .= $_;
        }
        close(PYERR) or die ("\# " . (localtime) . " ERROR: in file " 
            . __FILE__
            ." at line ". __LINE__ ."\n"
            . "Could not close file $errorfile!\n");
        $prtStr .= "#*********\n";
        $logString .= $prtStr;
        $missingPython3Module = 1;
    }
    if($missingPython3Module == 1) {
        $prtStr = "Setting option --skipGetAnnoFromFasta. No FASTA"
                . " files of the gene predictions will be produced. Please "
                . " install re and biopython if you want those files produced "
                . " in future BRAKER runs.\n";
        $logString .= $prtStr;
        $skipGetAnnoFromFasta = 1;
        if( $makehub ) {
            $prtStr = "MakeHub requires the python modules re and "
                    . "biopython. No hub will be created because dependencies "
                    . " are missing. Please install re and biopython if you want "
                    . "hubs to be produced in future BRAKER runs.\n";
            $logString .= $prtStr;
            $makehub = 0;
        }
        print STDERR $logString;
    }
}

####################### set_PYTHON3_PATH #######################################
# * set path to python3 (for getAnnoFastaFromJoingenes.py, 
#   fix_in_frame_stop_codon_genes.py and make_hub.py)
################################################################################

sub set_PYTHON3_PATH {
    # try to get path from ENV
    if ( defined( $ENV{'PYTHON3_PATH'} ) && not (defined($python3_path)) ) {
        if ( -e $ENV{'PYTHON3_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$PYTHON3_PATH. Setting "
                . "\$PYTHON3_PATH to ".$ENV{'PYTHON3_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $PYTHON3_PATH = $ENV{'PYTHON3_PATH'};
        }
    }
    elsif(not(defined($python3_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$PYTHON3_PATH\n";
        $logString .= $prtStr if ($v > 1);
    }

    # try to get path from command line
    if ( defined($python3_path) ) {
        my $last_char = substr( $python3_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($python3_path);
        }
        if ( -d $python3_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$PYTHON3_PATH to command line argument "
                . "--PYTHON3_PATH value $python3_path.\n";
            $logString .= $prtStr if ($v > 1);
            $PYTHON3_PATH = $python3_path;
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Command line argument --PYTHON3_PATH was "
                    . "supplied but value $python3_path is not a directory. Will not "
                    . "set \$PYTHON3_PATH to $python3_path!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # try to guess
    if ( not( defined($PYTHON3_PATH) )
        || length($PYTHON3_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$PYTHON3_PATH from location of python3"
            . " executable that is available in your \$PATH\n";
        $logString .= $prtStr if ($v > 1);
        my $epath = which 'python3';
        if(defined($epath)){
            if ( -d dirname($epath) ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$PYTHON3_PATH to "
                    . dirname($epath) . "\n";
                $logString .= $prtStr if ($v > 1);
                $PYTHON3_PATH = dirname($epath);
            }
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Guessing the location of \$PYTHON3_PATH "
                    . "failed / BRAKER failed "
                    . "to detect python3 with \"which python3\"!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    if ( not( defined($PYTHON3_PATH) ) ) {
        my $python_err;
        $python_err .= "Python3 is currently required for converting\n"
                    .  "gene predictions in GTF-format and a genome\n"
                    .  "file in FASTA-format to FASTA files with coding\n"
                    .  "sequences and protein sequences using the AUGUSTUS\n"
                    .  "script getAnnoFastaJoingenes.py with braker.pl,\n"
                    .  "and for creating track data hubs for visualizing\n"
                    .  "gene predictions with the UCSC Genome Browser, and\n"
                    .  " for fixing genes with in frame stop codons.\n"
                    .  "You can skip execution of getAnnoFastaJoingenes.py\n"
                    .  "with the braker.pl command line flag --skipGetAnnoFromFasta.\n"
                    .  "You can skip generation of track data hubs by not providing\n"
                    .  "the command line option --makehub."
                    .  "You can skip the fixing of genes with stop codons with the\n"
                    .  " braker.pl command line flag --skip_fixing_broken_genes.\n"
                    .  "If you don't want to skip it, you have 3 different "
                    .  "options to provide a path to python3 to braker.pl:\n"
                    .  "   a) provide command-line argument\n"
                    .  "      --PYTHON3_PATH=/your/path\n"
                    .  "   b) use an existing environment variable\n"
                    . "       \$PYTHON3_PATH\n"
                    .  "      for setting the environment variable, run\n"
                    .  "           export PYTHON3_PATH=/your/path\n"
                    .  "      in your shell. You may append this to your "
                    .  ".bashrc or .profile file in\n"
                    .  "      order to make the variable available to all your\n"
                    .  "      bash sessions.\n"
                    .  "   c) braker.pl can try guessing the location of\n"
                    .  "      \$PYTHON3_PATH from the location of a python3\n"
                    .  "      executable that is available in your \$PATH\n"
                    .  "      variable. If you try to rely on this option, you\n"
                    . "       can check by typing\n"
                    .  "           which python3\n"
                    .  "      in your shell, whether there is a python3\n"
                    .  "      executable in your \$PATH\n";
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            . " at line ". __LINE__ . "\n" . "\$PYTHON3_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $python_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }
    if ( not ( -x "$PYTHON3_PATH/python3" ) ) {
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\n"
            . "$PYTHON3_PATH/python3 is not an executable file!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }
}

####################### set_CDBTOOLS_PATH #######################################
# * set path to cdbfasta/cdbyank
################################################################################

sub set_CDBTOOLS_PATH {
    # try to get path from ENV
    if ( defined( $ENV{'CDBTOOLS_PATH'} ) && not (defined($cdbtools_path)) ) {
        if ( -e $ENV{'CDBTOOLS_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$CDBTOOLS_PATH. Setting "
                . "\$CDBTOOLS_PATH to ".$ENV{'CDBTOOLS_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $CDBTOOLS_PATH = $ENV{'CDBTOOLS_PATH'};
        }
    }elsif(not(defined($cdbtools_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$CDBTOOLS_PATH\n";
        $logString .= $prtStr if ($v > 1);
    }

    # try to get path from command line
    if ( defined($cdbtools_path) ) {
        my $last_char = substr( $cdbtools_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($cdbtools_path);
        }
        if ( -d $cdbtools_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$CDBTOOLS_PATH to command line argument "
                . "--CDBTOOLS_PATH value $cdbtools_path.\n";
            $logString .= $prtStr if ($v > 1);
            $CDBTOOLS_PATH = $cdbtools_path;
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Command line argument --CDBTOOLS_PATH was "
                    . "supplied but value $cdbtools_path is not a directory. Will not "
                    . "set \$CDBTOOLS_PATH to $cdbtools_path!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # try to guess
    if ( not( defined($CDBTOOLS_PATH) )
        || length($CDBTOOLS_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$CDBTOOLS_PATH from location of cdbfasta"
            . " executable that is available in your \$PATH\n";
        $logString .= $prtStr if ($v > 1);
        my $epath = which 'cdbfasta';
        if(defined($epath)){
            if ( -d dirname($epath) ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$CDBTOOLS_PATH to "
                    . dirname($epath) . "\n";
                $logString .= $prtStr if ($v > 1);
                $CDBTOOLS_PATH = dirname($epath);
            }
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Guessing the location of \$CDBTOOLS_PATH "
                    . "failed / BRAKER failed "
                    . "to detect cdbfasta with \"which cdbfasta\"!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    if ( not( defined($CDBTOOLS_PATH) ) ) {
        my $cdbtools_err;
        $cdbtools_err .= "cdbfasta and cdbyank are required for fixing AUGUSTUS "
                    .  "genes with in frame stop codons using the script "
                    .  "fix_in_frame_stop_codon_genes.py.\n"
                    .  "You can skip execution of fix_in_frame_stop_codon_genes.py\n"
                    .  "with the braker.pl by providing the command line flag\n"
                    .  "--skip_fixing_broken_genes.\n"
                    .  "If you don't want to skip it, you have 3 different "
                    .  "options to provide a path to cdbfasta/cdbyank to braker.pl:\n"
                    .  "   a) provide command-line argument\n"
                    .  "      --CDBTOOLS_PATH=/your/path\n"
                    .  "   b) use an existing environment variable\n"
                    . "       \$CDBTOOLS_PATH\n"
                    .  "      for setting the environment variable, run\n"
                    .  "           export CDBTOOLS_PATH=/your/path\n"
                    .  "      in your shell. You may append this to your "
                    .  ".bashrc or .profile file in\n"
                    .  "      order to make the variable available to all your\n"
                    .  "      bash sessions.\n"
                    .  "   c) braker.pl can try guessing the "
                    .  "      \$CDBTOOLS_PATH from the location of a cdbfasta\n"
                    .  "      executable that is available in your \$PATH\n"
                    .  "      variable. If you try to rely on this option, you\n"
                    . "       can check by typing\n"
                    .  "           which cdbfasta\n"
                    .  "      in your shell, whether there is a cdbfasta\n"
                    .  "      executable in your \$PATH\n";
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            . " at line ". __LINE__ . "\n" . "\$CDBTOOLS_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $cdbtools_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }
    if ( not ( -x "$CDBTOOLS_PATH/cdbfasta" ) ) {
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\n"
            . "$CDBTOOLS_PATH/cdbfasta is not an executable file!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }elsif ( not ( -x "$CDBTOOLS_PATH/cdbyank" ) ) {
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\n"
            . "$CDBTOOLS_PATH/cdbyank is not an executable file!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }
}


####################### set_MAKEHUB_PATH #######################################
# * set path to make_hub.py
################################################################################

sub set_MAKEHUB_PATH {
    # try to get path from ENV
    if ( defined( $ENV{'MAKEHUB_PATH'} ) && not (defined($makehub_path)) ) {
        if ( -e $ENV{'MAKEHUB_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$MAKEHUB_PATH. Setting "
                . "\$MAKEHUB_PATH to ".$ENV{'MAKEHUB_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $MAKEHUB_PATH = $ENV{'MAKEHUB_PATH'};
        }
    }elsif(not(defined($makehub_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$MAKEHUB_PATH\n";
        $logString .= $prtStr if ($v > 1);
    }

    # try to get path from command line
    if ( defined($makehub_path) ) {
        my $last_char = substr( $makehub_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($makehub_path);
        }
        if ( -d $makehub_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$MAKEHUB_PATH to command line argument "
                . "--MAKEHUB_PATH value $makehub_path.\n";
            $logString .= $prtStr if ($v > 1);
            $MAKEHUB_PATH = $makehub_path;
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Command line argument --MAKEHUB_PATH was "
                    . "supplied but value $makehub_path is not a directory. Will not "
                    . "set \$MAKEHUB_PATH to $makehub_path!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # try to guess
    if ( not( defined($MAKEHUB_PATH) )
        || length($MAKEHUB_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$MAKEHUB_PATH from location of make_hub.py"
            . " executable that is available in your \$PATH\n";
        $logString .= $prtStr if ($v > 1);
        my $epath = which 'make_hub.py';
        if(defined($epath)){
            if ( -d dirname($epath) ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$MAKEHUB_PATH to "
                    . dirname($epath) . "\n";
                $logString .= $prtStr if ($v > 1);
                $MAKEHUB_PATH = dirname($epath);
            }
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Guessing the location of \$MAKEHUB_PATH "
                    . "failed / BRAKER failed "
                    . "to detect make_hub.py with \"which make_hub.py\"!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    if ( not( defined($MAKEHUB_PATH) ) ) {
        my $makehub_err;
        $makehub_err .= "make_hub.py is required for generating track data\n"
                    .  "hubs for visualizing gene predictions with the UCSC\n"
                    .  "Genome Browser. You can skip execution of make_hub.py\n"
                    .  "with the braker.pl by not providing the command line flag\n"
                    .  "--makehub.\n"
                    .  "If you don't want to skip it, you have 3 different "
                    .  "options to provide a path to make_hub.py to braker.pl:\n"
                    .  "   a) provide command-line argument\n"
                    .  "      --MAKEHUB_PATH=/your/path\n"
                    .  "   b) use an existing environment variable\n"
                    . "       \$MAKEHUB_PATH\n"
                    .  "      for setting the environment variable, run\n"
                    .  "           export MAKEHUB_PATH=/your/path\n"
                    .  "      in your shell. You may append this to your "
                    .  ".bashrc or .profile file in\n"
                    .  "      order to make the variable available to all your\n"
                    .  "      bash sessions.\n"
                    .  "   c) braker.pl can try guessing the location of\n"
                    .  "      \$MAKEHUB_PATH from the location of a make_hub.py\n"
                    .  "      executable that is available in your \$PATH\n"
                    .  "      variable. If you try to rely on this option, you\n"
                    . "       can check by typing\n"
                    .  "           which make_hub.py\n"
                    .  "      in your shell, whether there is a make_hub.py\n"
                    .  "      executable in your \$PATH\n";
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            . " at line ". __LINE__ . "\n" . "\$MAKEHUB_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $makehub_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }
    if ( not ( -x "$MAKEHUB_PATH/make_hub.py" ) ) {
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\n"
            . "$MAKEHUB_PATH/make_hub.py is not an executable file!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }
}

####################### check_upfront ##########################################
# * check for scripts, perl modules, executables, extrinsic config files
################################################################################

sub check_upfront {

    # check whether required perl modules are installed
    my $pmodule;
    my @module_list = (
        "YAML",           "Hash::Merge",
        "Logger::Simple", "Parallel::ForkManager",
        "Scalar::Util::Numeric", "Getopt::Long",
        "File::Compare", "File::Path", "Module::Load::Conditional",
        "Scalar::Util::Numeric", "POSIX", "List::Util",
        "FindBin", "File::Which", "Cwd", "File::Spec::Functions",
        "File::Basename", "File::Copy", "Term::ANSIColor",
        "strict", "warnings", "File::HomeDir", "List::MoreUtils",
        "Math::Utils"
    );

    foreach my $module (@module_list) {
        $pmodule = check_install( module => $module );
        if ( !$pmodule ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Perl module '$module' is required but not installed yet.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    # check for augustus executable
    $augpath = "$AUGUSTUS_BIN_PATH/augustus";
    if ( system("$augpath > /dev/null 2> /dev/null") != 0 ) {
        if ( !-f $augpath ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "augustus executable not found at $augpath.\n";
            $logString .= $prtStr;
        }
        else {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "$augpath not executable on this machine.\n";
            $logString .= $prtStr;
        }
        print STDERR $logString;
        exit(1);
    }

    # check for joingenes executable
    $augpath = "$AUGUSTUS_BIN_PATH/joingenes";
    if ( not (-x $augpath ) or not (-e $augpath ) ) {
        if ( !-f $augpath ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "joingenes executable not found at $augpath. Please compile "
                . "joingenes (augustus/auxprogs/joingenes)!\n";
            $logString .= $prtStr;
        }
        elsif(! -x $augpath){
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "$augpath not executable on this machine.  Please compile "
                . "joingenes (augustus/auxprogs/joingenes)!n";
            $logString .= $prtStr;
        }
        print STDERR $logString;
        exit(1);
    }

    # check whether bamtools is installed
    if( @bam ) {
        if ( system("which $BAMTOOLS_BIN_PATH/bamtools > /dev/null") != 0 ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "bamtools not installed. Please install it first.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    # check for etraining executable
    my $etrainpath;
    $etrainpath = "$AUGUSTUS_BIN_PATH/etraining";
    if ( system("$etrainpath > /dev/null 2> /dev/null") != 0 ) {
        if ( !-f $etrainpath ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "etraining executable not found at $etrainpath.\n";
            $logString .= $prtStr;
        }
        else {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "$etrainpath not executable on this machine.\n";
            $logString .= $prtStr;
        }
        print STDERR $logString;
        exit(1);
    }

    # check whether rnaseq2utr is executable
    $rnaseq2utr = "$AUGUSTUS_BIN_PATH/utrrnaseq";
    if ( $UTR eq "on" && $skipAllTraining == 0 ) {
        if ( not( -x $rnaseq2utr ) ) {
            if ( !-f $rnaseq2utr ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "rnaseq2utr executable not found at $rnaseq2utr.\n";
                $logString .= $prtStr;
            }
            else {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "$rnaseq2utr not executable on this machine.\n";
                $logString .= $prtStr;
            }
            $prtStr
                = "       UTR training from RNA-Seq is enabled. This requires "
                . "rnaseq2utr. Please check README.TXT of AUGUSTUS to compile "
                . "rnaseq2utr correctly.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    if(@prot_aln_files) {
        $foundProt++;
    }

    # check for alignment executable and in case of SPALN for environment variables
    my $prot_aligner;
    if (@prot_seq_files) {
        $foundProt++;
        if ( $prg eq 'gth' ) {
            $prot_aligner = "$ALIGNMENT_TOOL_PATH/gth";
            if ( !-f $prot_aligner ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "GenomeThreader executable not found at $prot_aligner.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
            elsif ( !-x $prot_aligner ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "$prot_aligner not executable on this machine.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
        }
        elsif ( $prg eq 'spaln' ) {
            $prot_aligner = "$ALIGNMENT_TOOL_PATH/spaln";
            if ( !-f $prot_aligner ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "Spaln executable not found at $prot_aligner.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
            elsif ( !-x $prot_aligner ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "$prot_aligner not executable on this machine.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }

            # check whether spaln environment variables are configured
            if ( !$ENV{'ALN_DBS'} or !$ENV{'ALN_TAB'} ) {
                if ( !$ENV{'ALN_DBS'} ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": ERROR: in file " . __FILE__ ." at line "
                        . __LINE__ . "\n"
                        . "The environment variable ALN_DBS for spaln is not "
                        . "defined. Please export an environment variable "
                        . "with: 'export ALN_DBS=/path/to/spaln/seqdb'\n";
                    $logString .= $prtStr;
                }
                if ( !$ENV{'ALN_TAB'} ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": ERROR: in file " . __FILE__ ." at line "
                        . __LINE__ ."\n" . "The environment variable ALN_TAB "
                        . "for spaln is not defined. Please export an "
                        . "environment variable with: "
                        . "'export ALN_TAB=/path/to/spaln/table'\n";
                    $logString .= $prtStr;
                }
                print STDERR $logString;
                exit(1);
            }
        }
        elsif ( $prg eq 'exonerate' ) {
            $prot_aligner = "$ALIGNMENT_TOOL_PATH/exonerate";
            if ( !-f $prot_aligner ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "Exonerate executable not found at $prot_aligner.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
            elsif ( !-x $prot_aligner ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "$prot_aligner not executable on this machine.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
        }
    }

    # check whether the necessary perl scripts exist and can be found
    find(
        "gff2gbSmallDNA.pl",    $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "filterGenemark.pl",    $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    if($lambda){
        find(
        "downsample_traingenes.pl",    $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    }
    find(
        "filterIntronsFindStrand.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH,       $AUGUSTUS_CONFIG_PATH
    );
    find(
        "new_species.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "filterGenesIn_mRNAname.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH,      $AUGUSTUS_CONFIG_PATH
    );
    find(
        "filterGenes.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH,      $AUGUSTUS_CONFIG_PATH
    );
    find(
        "filterGenesIn.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH,      $AUGUSTUS_CONFIG_PATH
    );
    find(
        "join_mult_hints.pl",   $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "aa2nonred.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH,      $AUGUSTUS_CONFIG_PATH
    );
    find(
        "randomSplit.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "optimize_augustus.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find("log_reg_prothints.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "join_aug_pred.pl",     $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "getAnnoFastaFromJoingenes.py", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
      );
    if($UTR eq "on"){
        find(
            "bamToWig.py", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
      );
    }
    find(
        "gtf2gff.pl",           $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "startAlign.pl",        $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "align2hints.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "splitMfasta.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "createAugustusJoblist.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "gtf2gff.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "fix_joingenes_gtf.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "merge_transcript_sets.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    if(not($skip_fixing_broken_genes)){
        find(
            "fix_in_frame_stop_codon_genes.py", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
    }
    if(defined($annot)){
        find(
            "compare_intervals_exact.pl", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        find(
            "compute_accuracies.sh", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
    }

    # check whether all extrinsic cfg files are available
    find_ex_cfg ("cfg/rnaseq.cfg");
    find_ex_cfg ("cfg/ep.cfg");
    find_ex_cfg ("cfg/gth.cfg");
    find_ex_cfg ("cfg/rnaseq_utr.cfg");
    find_ex_cfg ("cfg/ep_utr.cfg");
    find_ex_cfg ("cfg/gth_utr.cfg");

    # check whether provided translation table is compatible
    # BRAKER has only been implemented to alter to nuclear code
    # tables, instead of table 1 ...\
    if(not($ttable eq 1)){
        if(not($ttable =~ m/^(6|10|12|25|26|27|28|29|30|31)$/)){
            $prtStr = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "BRAKER is only compatible with translation tables " 
                  . "1, 6, 10, 12, 25, 26, 27, 28, 29, 30, 31. You "
                  . "specified table " + $ttable + ".\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
        }
    }
    # check for bamToWig.py required UCSC tools
    if( $UTR eq "on" ){
        if ( system("which twoBitInfo > /dev/null") != 0 ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "twoBitInfo not installed. "
                . "It is available at http://hgdownload.soe.ucsc.edu/admin/exe "
                . "and should be added to your \$PATH. bamToWig.py will "
                . "automatically download this tool to the working directory but "
                . "permanent global installation is recommended.\n";
            $logString .= $prtStr;
            print STDERR $logString;
        }
        if ( system("which faToTwoBit > /dev/null") != 0 ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "faToTwoBit not installed. "
                . "It is available at http://hgdownload.soe.ucsc.edu/admin/exe "
                . "and should be added to your \$PATH. bamToWig.py will "
                . "automatically download this tool to the working directory but "
                . "permanent global installation is recommended.\n";
            $logString .= $prtStr;
            print STDERR $logString;
        }
    }
}

####################### find_ex_cfg ############################################
# * find extrinsic config file
################################################################################

sub find_ex_cfg {
    my $thisCfg = shift;
    $string = find( $thisCfg, $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH,
        $AUGUSTUS_CONFIG_PATH );
    if ( not ( -e $string ) ) {
        $prtStr
            = "\# "
            . (localtime)
            . " ERROR: tried to find braker's extrinsic.cfg file $thisCfg "
            . "$string but this file does not seem to exist.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }
}

####################### check_gff ##############################################
# * check that user provided hints file is in valid gff format
# * check that hints file only contains supported hint types (extrinsic.cfg)
#   compatibility
################################################################################

sub check_gff {
    my $gfffile = shift;
    $prtStr
        = "\# "
        . (localtime)
        . ": Checking if input file $gfffile is in gff format\n";
    $logString .= $prtStr if ($v > 2);
    open( GFF, $gfffile ) or die ( "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nCannot open file: $gfffile\n" );
    my $nIntrons            = 0;
    my $printedAllowedHints = 0;
    my %foundFeatures;

    my $gffC = 0;
    while (<GFF>) {
        $gffC++;
        my @gff_line = split( /\t/, $_ );
        if ( scalar(@gff_line) != 9 ) {
            $prtStr
                = "\# "
                . (localtime)
                . " ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "File $gfffile is not in gff format at line $gffC!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            close(GFF) or die("ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nCould not close gff file $gfffile!\n");
            exit(1);
        }
        else {
            if (   !isint( $gff_line[3] )
                || !isint( $gff_line[4] )
                || $gff_line[5] =~ m/[^\d\.]/g
                || $gff_line[6] !~ m/[\+\-\.]/
                || length( $gff_line[6] ) != 1
                || $gff_line[7] !~ m/[0-2\.]{1}/
                || length( $gff_line[7] ) != 1 )
            {
                $prtStr
                    = "\# "
                    . (localtime)
                    . " ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "File $gfffile is not in gff format!\n";
                $logString .= $prtStr;
                print STDERR $logString;
                close(GFF) or die("ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not close gff file $gfffile!\n");
                exit(1);
            }
        }

        # intron hints are the sole source of extrinsic information for
        # GeneMark-ET, thus, if no bam file is given, the
        # supplied hints file must contain intron hints (many)
        if ( !@bam ) {
            if ( $gff_line[2] eq "intron" ) {
                $nIntrons++;
            }
        }

        # if no extrinsic.cfg is specified, parameters in braker.pl written
        # extrinsic.cfg correspond to hints in @allowedHints, only; other
        # hints will be treated with neutral malus/bonus. Issue corresponding
        # warning.
        if ( not( defined($extrinsicCfgFile) ) ) {
            my $isAllowed = 0;
            foreach (@allowedHints) {
                if ( $gff_line[2] eq $_ ) {
                    $isAllowed = 1;
                }
            }
            if ( $isAllowed != 1 ) {
                if ( not( defined( $foundFeatures{ $gff_line[2] } ) ) ) {
                    $prtStr = "#*********\n"
                            . "# WARNING: File $gfffile contains hints of a feature "
                            . "type $gff_line[2] that is currently not supported "
                            . "by BRAKER. Features of this type will be treated "
                            . "with neutral bonus/malus in the extrinsic.cfg file "
                            . "that will be used for running AUGUSTUS.\n"
                            . "#*********\n";
                    $logString .= $prtStr if ( $v > 0 );
                    $foundFeatures{ $gff_line[2] } = 1;
                }
                if ( $printedAllowedHints == 0 ) {
                    $prtStr = "Currently allowed hint types:\n";
                    $logString .= $prtStr if ( $v > 0 );
                    foreach (@allowedHints) {
                        $prtStr = $_ . "\n";
                        $logString .= $prtStr if ( $v > 0 );
                    }
                    $printedAllowedHints = 1;
                }
            }
        }
    }
    close(GFF) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nCould not close gff file $gfffile!\n");
    if ( !@bam && !$skipAllTraining) {
        if ( $nIntrons < 1000 ) {
            $prtStr = "#*********\n"
                    . "# WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "Since no bam file was supplied, GeneMark-ET must take "
                    . "intron information from hints file $gfffile. This file "
                    . "contains only $nIntrons intron hints. GeneMark-ET training "
                    . "will thus likely fail.!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
            print STDOUT $logString if ($v > 0);
        }
    }
}

####################### check_options ##########################################
# * check that command line options are set, correctly
################################################################################

sub check_options {

    # Set implicit options:
    if ($skipAllTraining) {
        $useexisting = 1;
    }

    if ($trainFromGth) {
        $gth2traingenes = 1;
        $skipGeneMarkET = 1;
        $skipGeneMarkEP = 1;
        $skipGeneMarkETP = 1;
        $skipGeneMarkES = 1;
    }

    if ($skipAllTraining) {
        $skipoptimize = 1;
        $skipGeneMarkET = 1;
        $skipGeneMarkEP = 1;
        $skipGeneMarkETP = 1;
        $skipGeneMarkES = 1;
    }

    if ( defined($geneMarkGtf) ) {
        $skipGeneMarkET = 1;
        $skipGeneMarkEP = 1;
        $skipGeneMarkETP = 1;
        $skipGeneMarkES = 1;
    }

    if (@stranded) {
        my @split_stranded = split(/,/, $stranded[0]);
        @stranded = @split_stranded;
        foreach(@stranded){
            if(not($_ =~ m/\+/) && not($_ =~ m/-/) && not($_ =~ m/\./)){
                $prtStr = "\# " . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line "
                    . __LINE__ . "\n" . "arguments for --stranded can be: "
                    . "+, -, . The provided argument $_ is invalid!\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
        }
        if(not(scalar(@stranded) == scalar(@bam))){
            $prtStr = "\# " . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line "
                . __LINE__ . "\n" . "number of arguments for --bam (here "
                . scalar(@bam)
                . ") must be the same as number of arguments for --stranded (here "
                . scalar(@stranded)
                . ")!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }
    if( $CPU > 48 ) {
        $prtStr = "#*********\n"
                . "# WARNING: The number of cores was set "
                . "to $CPU, which is greater than 48. GeneMark has in the past "
                . " been reported to "
                . "die if you set such a high number of cores. Please "
                . "be aware that a very large number of cores also may not "
                . "be used efficiently by optimize_augustus.pl during "
                . "cross validation. braker.pl will automatically compute the "
                . "number of cores that will effectively be used for "
                . "optimizing AUGUSTUS parameter in such a way that "
                . "each bucket will contain at least 200 training genes. We "
                . "usually use 8 cores for 8-fold cross validation.\n"
                . "#*********\n";
        print STDOUT $prtStr;
        $logString .= $prtStr;
    }

    # UTR training only
    if ( defined($AUGUSTUS_hints_preds) ) {
        $skipoptimize = 1;
        $skipGeneMarkET = 1;
        $skipGeneMarkEP = 1;
        $skipGeneMarkETP = 1;
        $skipGeneMarkES = 1;
        $UTR = "on";
        if( defined($hintsfile) ) {
            $prtStr = "\# " . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line "
                    . __LINE__ . "\n" . "--hintsfile cannot be specified "
                    . "if --AUGUSTUS_hints_preds=s is given. Must specify "
                    . "--bam (only)!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
        if( !@bam ) {
            $prtStr = "\# " . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line "
                    . __LINE__ . "\n" . "Must specify "
                    . "--bam (as only evidence source) for UTR parameter "
                    . "training!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    # if UTR is on, check whether splice site patterns are given
    if( $UTR eq "on") {
        if( @splice_cmd_line ){
            my $gtag_ever_seen = 0;
            foreach(@splice_cmd_line){
                if($_ =~ m/gtag/i){
                    $gtag_ever_seen = 1;
                }
                if(length($_) > 4 or ($_=~m/[^ATCGatcg]/) ){
                    $prtStr = "\# " . (localtime)
                            . ": ERROR: in file " . __FILE__ ." at line "
                            . __LINE__ . "\n" . "--splice_pattern invalid; "
                            . "each pattern must consist of exactly 4 "
                            . "nucleotides of the set [ATCGatcg]!\n";
                    $logString .= $prtStr;
                    print STDERR $logString;
                    exit(1);
                }else{
                    push(@splice, uc($_));
                }
            }
            if($gtag_ever_seen == 0){
                $prtStr = "#*********\n"
                        . "# WARNING: in file " . __FILE__ ." at line "
                        . __LINE__ . "\n" . " Splice site pattern ATAG was "
                        . "not in the list of splice site patterns. This "
                        . "is probably a mistake?\n"
                        . "#*********\n";
                $logString .= $prtStr;
                print STDOUT $prtStr;
            }
        }else{
            @splice = ("GTAG");
        }
    }

    if ( $EPmode == 1 && $ETPmode == 1 ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "--epmode and --etpmode cannot be set simultaneously!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if ( $EPmode == 1 && $ESmode == 1 ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "--epmode and --esmode cannot be set simultaneously!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if ( $ETPmode && $ESmode == 1 ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "--etpmode and --esmode cannot be set simultaneously!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if (   $alternatives_from_evidence ne "true"
        && $alternatives_from_evidence ne "false" )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "\"$alternatives_from_evidence\" is not a valid option for "
            . "--alternatives-from-evidence. Please use either 'true' or "
            . "'false'.\n";
        print STDERR $prtStr;
        $logString .= $prtStr;
        exit(1);
    }

    if ( $UTR ne "on" && $UTR ne "off" ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "\"$UTR\" is not a valid option for --UTR. Please use either "
            . "'on' or 'off'.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if (   ( $UTR eq "on" && $soft_mask == 0 )
        or ( $UTR eq "on" && not(@bam) ) )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "--UTR=on has been set but --softmasking has not been enabled. "
            . "A softmasked genome file and the option --softmasking and a "
            . "bam file must be provided in order to run --UTR=on (in contrast "
            . "to other modes, where a hints file can replace the alignment "
            . "file, the bam file is strictly required for UTR training).\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }
    
    my $cpus_available = `getconf _NPROCESSORS_ONLN`;

    if ( $cpus_available < $CPU ) {
        $prtStr = "#*********\n" 
                . "# WARNING: Your system does not have $CPU cores available, "
                . "only $cpus_available. Braker will use the $cpus_available "
                . " available instead of the chosen $CPU.\n"
                . "#*********\n";
        $logString .= $prtStr if ($v > 0);
    }

    # check whether bam files exist (if given)
    if (@bam) {
        for ( my $i = 0; $i < scalar(@bam); $i++ ) {
            if ( !-e $bam[$i] ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__
                    ."\nBAM file $bam[$i] does not exist.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
        }
    }

    # check whether hints files exists
    if (@hints) {
        for ( my $i = 0; $i < scalar(@hints); $i++ ) {
            if ( !-e "$hints[$i]" ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__
                    ."\nHints file $hints[$i] does not exist.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
            check_gff( $hints[$i] );
        }
    }

    # check what what hint sources are in hints file
    if(@bam){
        $foundRNASeq = 1;
    }
    if(@hints){
         foreach (@hints) {
            $foundRNASeq += check_hints($_);
        }
    }


    # check whether RNA-Seq files are specified
    if ( !@bam && !@hints && $EPmode == 0 && !$trainFromGth & !$skipAllTraining 
        && !$ESmode ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "No RNA-Seq or hints file(s) from RNA-Seq specified. "
            . "Please set at least one RNAseq BAM file or at least one hints "
            . "file from RNA-Seq (must contain intron hints from src b2h in "
            . "column 2) to run BRAKER in mode for training from RNA-Seq.\n"
            . "$usage";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if ( $EPmode == 1 ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": BRAKER will execute GeneMark-EP for training GeneMark and "
            . "generating a training gene set for AUGUSTUS, using protein "
            . "information as sole extrinsic evidence source.\n";
        $logString .= $prtStr if ($v > 1);
    }

    if( ((($EPmode == 1 || $ETPmode == 1) && not(defined($evidence_hints) )  && not(defined($prothint_file))) == 1) 
        && ((($EPmode == 1 || $ETPmode == 1) && not(defined($hintsfile)) &&  scalar(@prot_seq_files)<0 && not($prg eq "ph")) == 1) ){
        $prtStr = "\# "
                 . (localtime)
                 . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                 . "If option --epmode is used, either the options \"--prg=ph "
                 . "--prot_seq=proteins.fasta\" (to run ProtHint) or the options "
                 . "\"--evidence=evidence.gff --prothints=prothint.gff "
                 . "--hints=prothint_augustus.gff,evidence_augustus.gff\" "
                 . "(output files of ProtHint) must be specified!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    # check whether species is specified
    if ( defined($species) ) {
        if ( $species =~ /[\s]/ ) {
            $prtStr = "#*********\n"
                ."# WARNING: Species name contains invalid white space "
                . "characters. Will replace white spaces with underline "
                . "character '_'.\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
            $species =~ s/\s/\_/g;
        }
        foreach my $word (@forbidden_words) {
            if ( $species eq $word ) {
                $prtStr = "#*********\n"
                        . "# WARNING: $species is not allowed as a species name.\n"
                        . "#*********\n";
                $logString .= $prtStr if ($v > 0);
                $bool_species = "false";
            }
        }
    }

    # use standard name when no name is assigned or when it contains invalid parts
    if ( !defined($species) || $bool_species eq "false" ) {
        my $no = 1;
        $species = "Sp_$no";
        while ( $no <= $limit ) {
            $species = "Sp_$no";
            if ( ( !-d "$AUGUSTUS_CONFIG_PATH/species/$species" ) ) {
                last;
            }
            else {
                $no++;
            }
        }
        if ( $no > $limit ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "There are already $limit species folders under "
                . "$AUGUSTUS_CONFIG_PATH/species/ of type 'Sp_$limit'. "
                . "Please delete or move some of those folders or assign a "
                . "valid species identifier with --species=name.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
        if ( $bool_species eq "false" ) {
            $prtStr = "\# " . (localtime) . ": Program will use $species instead.\n";
            $logString .= $prtStr if ($v > 0);
        }
        else {
            $prtStr
                = "#*********\n"
                . "# IMPORTANT INFORMATION: no species for identifying the AUGUSTUS "
                . " parameter set that will arise from this BRAKER run was set. BRAKER "
                . "will create an AUGUSTUS parameter set with name $species. "
                . "This parameter set can be used for future BRAKER/AUGUSTUS prediction "
                . "runs for the same species. It is usually not necessary to retrain "
                . "AUGUSTUS with novel extrinsic data if a high quality parameter "
                . "set already exists.\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # check species directory
    if ( -d "$AUGUSTUS_CONFIG_PATH/species/$species" && !$useexisting ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "$AUGUSTUS_CONFIG_PATH/species/$species already exists. "
            . "Choose another species name, delete this directory or use the "
            . "existing species with the option --useexisting. Be aware that "
            . "existing parameters will then be overwritten during training.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if ( !-d "$AUGUSTUS_CONFIG_PATH/species/$species" && $useexisting ) {
        $prtStr = "#*********\n"
                . "# WARNING: $AUGUSTUS_CONFIG_PATH/species/$species does not "
                . "exist. Braker will create the necessary files for species "
                . "$species.\n"
                . "#*********\n";
        $logString .= $prtStr if($v > 0);
        $useexisting = 0;
    }

    # check whether a valid set of input files is provided
    if (   ( !@bam && !@hints )
        && ( !$trainFromGth && !@hints )
        && ( !$trainFromGth && !@prot_seq_files )
        && ( !$trainFromGth && !@prot_aln_files ) 
        && ( !$ESmode ))
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "in addition to a genome file, braker.pl requires at "
            . "least one of the following files/flags as input (unless "
            . "you run braker.pl --esmode):\n"
            . "    --bam=file.bam\n"
            . "    --hints=file.hints\n"
            . "    --prot_seq=file.fa --trainFromGth\n"
            . "    --prot_aln=file.aln --trainFromGth\n$usage";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if ( $ESmode && (@bam || @hints || @prot_seq_files || @prot_aln_files ) ) {
        $prtStr = "\# " . (localtime) . ": ERROR: Options --bam, --hints, "
                . "--prot_seq, --prot_aln are not allowed if option --esmode "
                . "is specified!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }


    # set extrinsic.cfg files if provided
    if (@extrinsicCfgFiles) {
        my $exLimit;
        if( $UTR eq "on" ) {
            $exLimit = 4;
        }else{
            $exLimit = 2;
        }
        if( scalar(@extrinsicCfgFiles) < ($exLimit+1) ) {
            for(my $i = 0; $i < scalar(@extrinsicCfgFiles); $i++ ) {
                if(-f $extrinsicCfgFiles[$i]) {
                    if($i == 0) {
                        $extrinsicCfgFile1 = $extrinsicCfgFiles[$i];
                    }elsif($i==1){
                        $extrinsicCfgFile2 = $extrinsicCfgFiles[$i];
                    }elsif($i==2){
                        $extrinsicCfgFile3 = $extrinsicCfgFiles[$i];
                    }elsif($i==3){
                        $extrinsicCfgFile4 = $extrinsicCfgFiles[$i];
                    }
                }else{
                    $prtStr = "\# " . (localtime)
                            . ": ERROR: specified extrinsic.cfg file "
                            . "$extrinsicCfgFiles[$i] does not exist!\n";
                    $logString .= $prtStr;
                    print STDERR $logString;
                    exit(1);
                }
            }
        }else{
            $prtStr = "\# "
                . (localtime)
                . ": ERROR: too many extrinsic.cfg files provided! If UTR is "
                . "off, at most two files are allowed (the first for "
                . "prediction with RNA-Seq and protein hints where proteins "
                . " have higher priority; the second for "
                . "prediction with RNA-Seq, only). If UTR is on, at most "
                . "four files are allowed (the third for prediction with "
                . "RNA-Seq and protein hints; the fourth for prediction with "
                . "RNA-Seq hints, only). If UTR is on and only RNA-Seq or "
                . "or only protein data is provided for hints, the first file "
                . "is used for predictions without UTR and the second for prediction "
                . "with UTR.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
        }
    }

    # check whether genome file is set
    if ( !defined($genome) ) {
        $prtStr
            = "\# " . (localtime) . ": ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\nNo genome file was specified.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    # check whether protein sequence file is given
    if (@prot_seq_files) {
        for ( my $i = 0; $i < scalar(@prot_seq_files); $i++ ) {
            if ( !-f $prot_seq_files[$i] ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "protein sequence file $prot_seq_files[$i] does "
                    . "not exist.\n";
            $logString .= $prtStr;
            print STDERR $logString;
                exit(1);
            }
        }
        if ( !defined($prg) && $EPmode == 0 && $ETPmode == 0) {

            # if no alignment tools was specified, set Genome Threader as default
            $prtStr = "#*********\n"
                    . "# WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "No alignment tool was specified for aligning protein"
                    . " sequences against genome. Setting GenomeThreader as "
                    . "default alignment tool.\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
            $prg = "gth";
        }
        elsif ( !defined($prg) && (($EPmode == 1)||($ETPmode==1)) ) {
            $prg = "ph";
            $prtStr = "#*********\n"
                    . "# WARNING: No alignment tool was specified for aligning "
                    . "protein sequences against genome. Setting ProSplign as "
                    . "default alignment tool for running BRAKER in GeneMark-EP or -ETP "
                    . "mode.\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0 );
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR:  in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Running ProSplign from within BRAKER is currently "
                . "not supported. Aborting braker.pl!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    # check whether reference annotation file exists
    if ($annot) {
        if ( not( -e $annot ) ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Reference annotation file $annot does not exist. Cannot "
                . "evaluate prediction accuracy!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    # check whether protein alignment file is given
    if (@prot_aln_files) {
        for ( my $i = 0; $i < scalar(@prot_aln_files); $i++ ) {
            if ( !-f $prot_aln_files[$i] ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__
                    ."\nprotein alignment file $prot_aln_files[$i] does"
                    . " not exist.\n";
            $logString .= $prtStr;
            print STDERR $logString;
                exit(1);
            }
        }
        if ( !defined($prg) ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "if protein alignment file is specified, you must "
                . "specify the source tool that was used to create that "
                . "alignment file, i.e. --prg=gth for GenomeThreader, or "
                . "--prg=spaln for Spaln2 or --prg=exonerate for Exonerate.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    # check whether alignment program is given
    if ( length($prg) > 0 ) {
        if (    not( $prg =~ m/gth/ )
            and not( $prg =~ m/exonerate/ )
            and not( $prg =~ m/spaln/ )
            and not( $prg =~ m/ph/)
            and $EPmode == 0  and $ETPmode == 0)
        {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "An alignment tool other than prothint (ph), gth, exonerate and spaln"
                . " has been specified with option --prg=$prg . BRAKER "
                . "currently only supports the options gth, exonerate and "
                . "spaln for running BRAKER in GeneMark-ET mode, and ProtHint "
                . "for running BRAKER in GeneMark-EP/-ETP mode. BRAKER was now "
                . "started in GeneMark-ET mode.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
        if ( (!@prot_seq_files and !@prot_aln_files) and not($skipAllTraining) ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "a protein alignment tool ($prg) has been given, "
                . "but neither a protein sequence file, nor a protein "
                . "alignment file generated by such a tool have been "
                . "specified.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    # check whether trainFromGth option is valid
    if ( defined($gth2traingenes) && not( $prg eq "gth" ) ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "Option --gth2traingenes can only be specified with "
            . "option --prg=gth!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    } elsif ( defined($trainFromGth) && not( $prg eq "gth" ) ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "Option --trainFromGth can only be specified with "
            . "option --prg=gth!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    } elsif ( ( defined ($trainFromGth) || $prg eq "gth" ) && ( $ETPmode == 1 ) ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "With --etpmode, usage of GenomeThreader is not supported "
                . "(options --gth2traingenes and --prg=gth)!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if ( !-f "$genome" ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "Genome file $genome does not exist.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if ($makehub && not($email)){
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "If --makehub option is used, --email argument value must be provided.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    } elsif (not($makehub) && $email) {
        $prtStr = "#*********\n"
                . "# WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "If --email option will only take effect in combination with --makehub option.\n"
                . "#*********\n";
        $logString .= $prtStr;
        print STDOUT $logString;
    }
}

####################### check_fasta_headers ####################################
# * check fasta headers (long and complex headers may cause problems)
# * tries to fix genome fasta files
# * only warns about portein fasta files
################################################################################

sub check_fasta_headers {
    my $fastaFile                = shift;
    my $genome_true              = shift;
    my $someThingWrongWithHeader = 0;
    my $spaces                   = 0;
    my $orSign                   = 0;
    my $emptyC                   = 0;
    my $wrongNL                  = 0;
    my $prot                     = 0;
    my $dna                      = 0;
    my $scaffName;
    my $mapFile = "$otherfilesDir/genome_header.map";
    my $stdStr = "This may later on cause problems! The pipeline will create "
               . "a new file without spaces or \"|\" characters and a "
               . "genome_header.map file to look up the old and new headers. This "
               . "message will be suppressed from now on!\n";

    print LOG "\# " . (localtime) . ": check_fasta_headers(): Checking "
                    . "fasta headers of file "
                    . "$fastaFile\n" if ($v > 2);
    open( FASTA, "<", $fastaFile )
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nCould not open fasta file $fastaFile!\n");
    if( $genome_true == 1 ){
        open( OUTPUT, ">", "$otherfilesDir/genome.fa" )
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__
                . "\nCould not open fasta file $otherfilesDir/genome.fa!\n");
        open( MAP, ">", $mapFile )
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nCould not open map file $mapFile.\n");
    }
    while (<FASTA>) {

        # check newline character
        if ( not( $_ =~ m/\n$/ ) ) {
            if ( $wrongNL < 1 ) {
                print LOG "#*********\n"
                    . "# WARNING: something seems to be wrong with the "
                    . "newline character! This is likely to cause problems "
                    . "with the braker.pl pipeline! Please adapt your file "
                    . "to UTF8! This warning will be supressed from now "
                    . "on!\n"
                    . "#*********\n" if ($v > 0);
                $wrongNL++;
            }
        }
        chomp;

        # look for whitespaces in fasta file
        if ( $_ =~ m/\s/ ) {
            if ( $spaces == 0 ) {
                $prtStr = "#*********\n"
                        . "# WARNING: Detected whitespace in fasta header of "
                        . "file $fastaFile. " . $stdStr
                        . "#*********\n";
                print LOG $prtStr if ($v > 2);
                print STDERR $prtStr;
                $spaces++;
            }
        }

        # look for | in fasta file
        if ( $_ =~ m/\|/ ) {
            if ( $orSign == 0 ) {
                $prtStr = "#*********\n"
                        . "# WARNING: Detected | in fasta header of file "
                        . "$fastaFile. " . $stdStr
                        . "#*********\n";
                print LOG $prtStr if ($v > 2);
                print STDERR $prtStr;
                $orSign++;
            }
        }

        # look for special characters in headers
        if ( ( $_ !~ m/[>a-zA-Z0-9]/ ) && ( $_ =~ m/^>/ ) ) {
            if ( $someThingWrongWithHeader == 0 ) {
                $prtStr = "#*********\n"
                        . " WARNING: Fasta headers in file $fastaFile seem to "
                        . "contain non-letter and non-number characters. That "
                        . "means they may contain some kind of special "
                        . "characters. "
                        . $stdStr
                        . "#*********\n";
                print LOG $prtStr if ($v > 2);
                print STDERR $prtStr;
                $someThingWrongWithHeader++;
            }
        }
        if ( ($_ =~ m/^>/) && ($genome_true == 1) ) {
            $scaffName = $_;
            $scaffName =~ s/^>//;
            # replace | and whitespaces by _
            my $oldHeader = $scaffName;
            $scaffName =~ s/\s/_/g;
            $scaffName =~ s/\|/_/g;
            print OUTPUT ">$scaffName\n";
            print MAP "$scaffName\t$oldHeader\n";
        }
        else {
            if ( length($_) > 0 ) {
                if($genome_true == 1){
                    print OUTPUT "$_\n";
                }
                if ( $_ !~ m/[ATGCNatgcn]/ ) {
                    if ( $dna == 0 ) {
                        print LOG "\# "
                            . (localtime)
                            . ": Assuming that this is not a DNA fasta "
                            . "file because other characters than A, T, G, "
                            . "C, N, a, t, g, c, n were contained. If this "
                            . "is supposed to be a DNA fasta file, check "
                            . "the content of your file! If this is "
                            . "supposed to be a protein fasta file, please "
                            . "ignore this message!\n" if ($v > 3);
                        $dna++;
                    }
                }
                if ( $_
                    !~ m/[AaRrNnDdCcEeQqGgHhIiLlKkMmFfPpSsTtWwYyVvBbZzJjXx]/
                    )
                {
                    if ( $prot == 0 ) {
                        print LOG "\# "
                            . (localtime)
                            . ": Assuming that this is not a protein fasta "
                            . "file because other characters than "
                            . "AaRrNnDdCcEeQqGgHhIiLlKkMmFfPpSsTtWwYyVvBbZzJjXx "
                            . "were contained. If this is supposed to be "
                            . "DNA fasta file, please ignore this "
                            . "message.\n" if ($v > 3);
                        $prot++;
                    }
                }
            }
            else {
                if ( $emptyC < 1 ) {
                    print LOG "#*********\n"
                        . " WARNING: empty line was removed! This warning "
                        . "will be supressed from now on!\n"
                        . "#*********\n" if ($v > 3);
                }
                $emptyC++;
            }
        }
    }
    close(FASTA) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line " . __LINE__
        ."\nCould not close fasta file $fastaFile!\n");
    if ($genome_true == 1){
        close(OUTPUT)
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nCould not close output fasta file "
                . "$otherfilesDir/genome.fa!\n");
        close(MAP) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close map file $mapFile!\n");
        $genome = "$otherfilesDir/genome.fa";
    }
}

####################### check_bam_headers ######################################
# * check bam headers
################################################################################

sub check_bam_headers {
    print LOG "\# " . (localtime) . ": Checking bam headers\n" if ($v > 2);
    my $bamFile                  = shift;
    my $someThingWrongWithHeader = 0;
    my $spaces                   = 0;
    my $orSign                   = 0;
    my %map_hash;
    my $mapFile = "$otherfilesDir/bam_header.map";
    my $stdStr
        = "This may later on cause problems! The pipeline will create a new "
        . "file without spaces or \"|\" characters and a bam_header.map file "
        . "to look up the old and new headers, if samtools is working on your "
        . "system. This message will be suppressed from now on!\n";
    @_ = split( /\//, $bamFile );
    @_ = split( /\./, $_[-1] );
    my $samHeaderFile     = "$otherfilesDir/" . $_[0] . "_header.sam";
    my $samHeaderFile_new = "$otherfilesDir/" . $_[0] . "_new_header.sam";

    if ( !uptodate( [$bamFile], ["$otherfilesDir/$bamFile"] ) || $overwrite )
    {
        # extract header information
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString
            .= "$BAMTOOLS_BIN_PATH/bamtools header -in $bamFile > $samHeaderFile";
        print LOG "\# "
            . (localtime)
            . ": create header file $samHeaderFile\n" if ($v > 3);
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            ." at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
        open( SAM, "<", $samHeaderFile )
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nCould not open SAM file $samHeaderFile!\n");
        open( OUTPUT, ">", "$samHeaderFile_new" )
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nCould not open SAM file $samHeaderFile_new!\n");
        open( MAP, ">", $mapFile )
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nCould not open map file $mapFile.\n");

        while (<SAM>) {
            chomp;

            # only check sequence entries
            if ( $_ =~ m/^\@SQ/ ) {
                my @seq_line = split( /\t/, $_ );
                my $seq_end = $seq_line[-1];
                @seq_line = split( /\:/, $seq_line[1] );
                my $old_name = $seq_line[1];
                my $new_name = $old_name;

                # remove whitespaces, if necessary
                @seq_line = split( /\s/, $seq_line[1] );
                if ( scalar(@seq_line) > 1 ) {
                    if ( $spaces == 0 ) {
                        print LOG "#*********\n"
                                . "# WARNING: Detected whitespace in BAM header of "
                                . "file $bamFile. " . $stdStr 
                                . "#*********\n" if ($v > 0);
                        $spaces++;
                    }
                }
                $new_name =~ s/\s/_/g;    # removing whitespaces (if any)
                @seq_line = split( /\|/, $old_name );
                if ( scalar(@seq_line) > 1 ) {
                    if ( $orSign == 0 ) {
                        print LOG "#*********\n"
                                . "# WARNING: Detected | in header of file "
                                . "$bamFile. " . $stdStr 
                                . "#*********\n"if ($v > 0);
                        print LOG "# Replacing | by underscores in Bam headers.\n" if ($v > 3);
                        $orSign++;
                    }
                }
                $new_name
                    =~ s/\|/_/g;    # replace or signs by underscores (if any)
                $map_hash{$old_name} = $new_name;
                $seq_line[0] = "\@SQ\tSN:$new_name\t$seq_end";
                if ( $seq_line[0] !~ m/[>a-zA-Z0-9]/ ) {
                    if ( $someThingWrongWithHeader == 0 ) {
                        print LOG "#*********\n"
                                . "# WARNING: BAM headers in file $bamFile seem to "
                                . "contain non-letter and non-number characters. "
                                . "That means they may contain some kind of "
                                . "special character. " . $stdStr 
                                . "#*********\n" if ($v > 0);
                        $someThingWrongWithHeader++;
                    }
                }
                print OUTPUT "$seq_line[0]\n";
                print MAP "$map_hash{$old_name}\t$old_name\n";
            }
            elsif (eof) {
                print OUTPUT "$_";
            }
            else {
                print OUTPUT "$_\n";
            }
        }
        close(SAM) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close header file $samHeaderFile!\n");
        close(OUTPUT)
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nCould not close output SAM file $samHeaderFile_new!\n");
        close(MAP) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close map file $mapFile!\n");
        print LOG "\# "
            . (localtime)
            . ": Deleting SAM header file $samHeaderFile (will not be needed "
            . "from here on)\n" if ($v > 3);
        unlink($samHeaderFile);

        # something wrong with header part
        if ( $spaces != 0 || $orSign != 0 || $someThingWrongWithHeader != 0 )
        {
            # no samtools installed. stop here
            if ( system("which samtools > /dev/null") != 0 ) {
                $prtStr = "\# "
                    . (localtime)
                    . " ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "BAM file $bamFile contains spaces, \"|\" or some other "
                    . "kind of special characters.\n"
                    . "'samtools' not installed. BAM file cannot be fixed "
                    . "automatically.\n";
                print LOG $prtStr;
                print STDERR $prtStr;
                exit(1);

                # samtools installed. try to correct BAM file
            }
            else {
                print CITE $pubs{'samtools'}; $pubs{'samtools'} = "";
                if ( not ( defined ($SAMTOOLS_PATH) ) ) {
                    $prtStr = "#*********\n"
                            . "# WARNING: The environment variable SAMTOOLS_PATH is "
                            . "not defined. Please export an environment variable "
                            . "for samtools or use "
                            . "--SAMTOOLS_PATH=path/to/samtools.\n"
                            . "The program will try to use '/usr/bin/samtools' to "
                            . "start samtools, which may not work on your "
                            . "system.\n"
                            . "#*********\n";
                    $SAMTOOLS_PATH = "/usr/bin";
                }
                my $samFile     = "$otherfilesDir/" . $_[0] . ".sam";
                my $samFile_new = "$otherfilesDir/" . $_[0] . "_new.sam";
                $cmdString = "";
                if ($nice) {
                    $cmdString .= "nice ";
                }
                $cmdString .= "$SAMTOOLS_PATH/samtools view -\@ ".($CPU-1)." $bamFile > $samFile";
                print LOG "\# "
                    . (localtime)
                    . ": convert BAM to SAM file $samFile\n" if ($v > 3);
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0
                    or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nfailed to execute: $cmdString!\n");
                open( SAM, "<", $samFile )
                    or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nCould not open SAM file $samFile!\n");
                open( OUTPUT, ">", "$samFile_new" )
                    or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nCould not open SAM file $samFile_new!\n");
                while (<SAM>) {
                    chomp;
                    my @line = split( /\t/, $_ );
                    $line[2] = $map_hash{ $line[2] };
                    if (eof) {
                        print OUTPUT join( "\t", @line );
                    }
                    else {
                        print OUTPUT join( "\t", @line ) . "\n";
                    }
                }
                close(SAM) or die("ERROR in file " . __FILE__ ." at line "
                    . __LINE__ . "\nCould not close SAM file $samFile!\n");
                close(OUTPUT)
                    or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nCould not close output SAM file $samFile_new!\n");
                $cmdString = "";
                if ($nice) {
                    $cmdString .= "nice ";
                }
                $cmdString
                    .= "cat $samHeaderFile_new $samFile_new > $samFile";
                print LOG "\# "
                    . (localtime)
                    . ": concatenate new header and SAM file\n" if ($v > 3);
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0
                    or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nfailed to execute: $cmdString!\n");
                print LOG "\# " . (localtime) . ": Deleting $samFile_new\n"
                    if ($v > 3);
                unlink($samFile_new);

                $cmdString = "";
                if ($nice) {
                    $cmdString .= "nice ";
                }
                $cmdString = "$SAMTOOLS_PATH/samtools view -\@ ".($CPU-1)." -bSh $samFile > $otherfilesDir/"
                           . $_[0] . ".bam";
                print LOG "\# "
                    . (localtime)
                    . ": Converting new SAM file to BAM format\n" if ($v > 3);
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0
                    or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nfailed to execute: $cmdString!\n");
                print LOG "\# " . (localtime) . ": Deleting $samFile\n"
                    if ($v > 3);
                unlink($samFile);
                $bamFile = "$otherfilesDir/" . $_[0] . ".bam";
            }
        }
        print LOG "\# " . (localtime) . ": Deleting $samHeaderFile_new\n"
            if ($v > 3);
        unlink($samHeaderFile_new);
    }
    return $bamFile;
}

####################### run_prothint ###########################################
# * execute ProtHint to produce protein hints
################################################################################

sub run_prothint {
    print LOG "\# " . (localtime)
        . ": Running ProtHint to produce hints from protein sequence file "
        . "(this may take a couple of hours)...\n" if ($v > 2);

    print CITE $pubs{'gm-ep'}; $pubs{'gm-ep'} = "";
    print CITE $pubs{'gm-es'}; $pubs{'gm-es'} = "";
    print CITE $pubs{'diamond'}; $pubs{'diamond'} = "";
    print CITE $pubs{'spaln'}; $pubs{'spaln'} = "";
    print CITE $pubs{'spaln2'}; $pubs{'spaln2'} = "";

    # step 1: remove dots from protein file and concatenate
    my $protein_file = $otherfilesDir."/proteins.fa";
    open(PROT_ALL, ">", $protein_file) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to open file $protein_file!\n");
    foreach(@prot_seq_files){
        open(PROT, "<", $_) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to open file $_!\n");
        while(<PROT>){
            my $line = $_;
            $line =~ s/\.//;
            print PROT_ALL $line;
        }
        close(PROT) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to close file $_!\n");
    }
    close(PROT_ALL) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to close file $protein_file!\n");

    # step 2: run GeneMark-ES for ProtHint
    print LOG "\# " . (localtime)
        . ": Running Genemark-ES for ProtHint...\n" if ($v > 3);
    GeneMark_ES($genemarkesDir);

    # step 3: call prothint
    print LOG "\# " . (localtime)
        . ": Calling prothint.py...\n" if ($v > 3);
    $cmdString = "";
    if ($nice) {
        $cmdString .= "nice ";
    }
    $cmdString = "$ALIGNMENT_TOOL_PATH/prothint.py --threads=$CPU --geneMarkGtf $genemarkesDir/genemark.gtf $otherfilesDir/genome.fa $otherfilesDir/proteins.fa";
    print LOG "\# " . (localtime) . ": starting prothint.py\n" if ($v > 3);
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__
        . " at line ". __LINE__
        . "\nFailed to execute $cmdString!\n");

    # step 4: modify evidence_augustus.gff
    print LOG "\# " . (localtime)
        . ": Changing hints source in evidence_augustus.gff from src=P to src=M...\n" if ($v > 3);
    my $ev_aug_tmp = $otherfilesDir."/evidence_augustus_tmp.gff";
    open(EV_AUG, "<", $otherfilesDir."/evidence_augustus.gff") or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to open file $otherfilesDir/evidence_augustus.gff!\n");
    open(EV_AUG_MOD, ">", $ev_aug_tmp) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to open file $ev_aug_tmp!\n");
    while(<EV_AUG>){
        my $line = $_;
        $line =~ s/src=P;/src=M;/;
        print EV_AUG_MOD $line;
    }
    close(EV_AUG_MOD) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to close file $ev_aug_tmp!\n");
    close(EV_AUG) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to close file $otherfilesDir/evidence_augustus.gff!\n");
    $cmdString = "mv $ev_aug_tmp $otherfilesDir/evidence_augustus.gff";
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");

    # step 5: modify top_chains.gff
    print LOG "\# " . (localtime)
        . ": Changing hints source in top_chains.gff from src=P to src=C...\n" if ($v > 3);
    my $top_chain_tmp = $otherfilesDir."/top_chains_tmp.gff";
    open(TOP_CH, "<", $otherfilesDir."/top_chains.gff") or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to open file $otherfilesDir/top_chains.gff!\n");
    open(TP_CH_MOD, ">", $top_chain_tmp) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to open file $top_chain_tmp!\n");
    while(<TOP_CH>){
        my $line = $_;
        $line =~ s/src=P;/src=MC;/;
        print TP_CH_MOD $line;
    }
    close(TP_CH_MOD) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to close file $top_chain_tmp!\n");
    close(TOP_CH) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to close file $otherfilesDir/top_chains.gff!\n");
    $cmdString = "mv $top_chain_tmp $otherfilesDir/top_chains.gff";
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");
        
    # step 5: logistic regression on prothint augustus hints (non src=M)
    print LOG "\# " . (localtime)
        . ": Applying logistic regression to separate hints in prothint.gff in two more classes...\n" if ($v > 3);
    $string = find(
        "log_reg_prothints.pl",     $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
     $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    $perlCmdString .= "perl $string --prothint=$otherfilesDir/prothint.gff "
        . "--out=$otherfilesDir/prothint_reg.gff 1> $otherfilesDir/prothint_reg.out "
        . "2>$errorfilesDir/prothint_reg.err";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to execute: $perlCmdString!\n"); 
    $cmdString = "mv $otherfilesDir/prothint_reg.gff $otherfilesDir/prothint_augustus.gff";
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");

    # step 6: add hints onto hintsfile.gff that need to go there
    print LOG "\# " . (localtime)
        . ": Appending hints from $otherfilesDir/evidence_augustus.gff to "
        . "$otherfilesDir/hintsfile.gff\n" if ($v > 3);
    open(HINTS, ">>", "$otherfilesDir/hintsfile.gff") or 
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to open file $otherfilesDir/hintsfile.gff!\n");
    # evidence_augustus.gff modified file
    open(EV_AUG, "<", "$otherfilesDir/evidence_augustus.gff") or 
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to open file $otherfilesDir/evidence_augustus.gff\n");
    while(<EV_AUG>){
        print HINTS $_;
    }
    close(EV_AUG) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to close file $otherfilesDir/evidence_augustus.gff\n");
    # modified top chains
    print LOG "\# " . (localtime)
        . ": Appending hints from $otherfilesDir/top_chains.gff to "
        . "$otherfilesDir/hintsfile.gff\n" if ($v > 3);
    open(TOP_CH, "<", "$otherfilesDir/top_chains.gff") or 
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to open file $otherfilesDir/top_chains.gff\n");
    while(<TOP_CH>){
        print HINTS $_;
    }
    close(TOP_CH) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to close file $otherfilesDir/top_chains.gff\n");
    # prothint_augustus.gff after logistic regression
    print LOG "\# " . (localtime)
        . ": Appending hints from $otherfilesDir/prothint_augustus.gff to "
        . "$otherfilesDir/hintsfile.gff\n" if ($v > 3);
    open(PHT, "<", "$otherfilesDir/prothint_augustus.gff") or 
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to open file $otherfilesDir/prothint_augustus.gff\n");
    while(<PHT>){
        print HINTS $_;
    }
    close(PHT) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to close file $otherfilesDir/prothint_augustus.gff\n");
    close(HINTS) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to close file $otherfilesDir/hintsfile.gff!\n");

    print LOG "\# " . (localtime)
        . ": Generating hints with ProtHint finished.\n" if ($v > 2);
}


####################### run_prothint_iter2 #####################################
# * execute ProtHint with additional seeds compared to run_prothint() from 
#   augustus.hints.gtf
################################################################################

sub run_prothint_iter2 {
    print LOG "\# " . (localtime)
        . ": Running ProtHint again with additional seeds from augustus.hints.gtf "
        . "to produce more hints from protein sequence file "
        . "(this may take a couple of hours)...\n" if ($v > 2);

    # step 1: call prothint
    print LOG "\# " . (localtime)
        . ": Calling prothint.py...\n" if ($v > 3);
    $cmdString = "";
    if ($nice) {
        $cmdString .= "nice ";
    }
    # THIS IS WHERE I AM, NEED TO MODIFY CALL, TODO!
    $cmdString = "$ALIGNMENT_TOOL_PATH/prothint.py --threads=$CPU --geneSeeds "
               . "$otherfilesDir/augustus.hints_iter1.gtf --prevGeneSeeds $otherfilesDir/GeneMark-ES/genemark.gtf "
               . "--prevSpalnGff $otherfilesDir/Spaln/spaln_iter1.gff $otherfilesDir/genome.fa "
               . "$otherfilesDir/proteins.fa";
    print LOG "\# " . (localtime) . ": starting prothint.py\n" if ($v > 3);
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__
        . " at line ". __LINE__
        . "\nFailed to execute $cmdString!\n");

    # step 2: modify evidence_augustus.gff
    print LOG "\# " . (localtime)
        . ": Changing hints source in evidence_augustus.gff from src=P to src=M...\n" if ($v > 3);
    my $ev_aug_tmp = $otherfilesDir."/evidence_augustus_tmp.gff";
    open(EV_AUG, "<", $otherfilesDir."/evidence_augustus.gff") or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to open file $otherfilesDir/evidence_augustus.gff!\n");
    open(EV_AUG_MOD, ">", $ev_aug_tmp) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to open file $ev_aug_tmp!\n");
    while(<EV_AUG>){
        my $line = $_;
        $line =~ s/src=P;/src=M;/;
        print EV_AUG_MOD $line;
    }
    close(EV_AUG_MOD) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to close file $ev_aug_tmp!\n");
    close(EV_AUG) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to close file $otherfilesDir/evidence_augustus.gff!\n");
    $cmdString = "mv $ev_aug_tmp $otherfilesDir/evidence_augustus.gff";
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");

    # step 3: modify top_chains.gff
    print LOG "\# " . (localtime)
        . ": Changing hints source in top_chains.gff from src=P to src=C...\n" if ($v > 3);
    my $top_chain_tmp = $otherfilesDir."/top_chains_tmp.gff";
    open(TOP_CH, "<", $otherfilesDir."/top_chains.gff") or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to open file $otherfilesDir/top_chains.gff!\n");
    open(TP_CH_MOD, ">", $top_chain_tmp) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to open file $top_chain_tmp!\n");
    while(<TOP_CH>){
        my $line = $_;
        $line =~ s/src=P;/src=MC;/;
        print TP_CH_MOD $line;
    }
    close(TP_CH_MOD) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to close file $top_chain_tmp!\n");
    close(TOP_CH) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nfailed to close file $otherfilesDir/top_chains.gff!\n");
    $cmdString = "mv $top_chain_tmp $otherfilesDir/top_chains.gff";
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");
        
    # step 4: logistic regression on prothint augustus hints (non src=M)
    print LOG "\# " . (localtime)
        . ": Applying logistic regression to separate hints in prothint.gff in two more classes...\n" if ($v > 3);
    $string = find(
        "log_reg_prothints.pl",     $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
     $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    $perlCmdString .= "perl $string --prothint=$otherfilesDir/prothint.gff "
        . "--out=$otherfilesDir/prothint_reg.gff 1> $otherfilesDir/prothint_reg.out "
        . "2>$errorfilesDir/prothint_reg.err";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to execute: $perlCmdString!\n"); 
    $cmdString = "mv $otherfilesDir/prothint_reg.gff $otherfilesDir/prothint_augustus.gff";
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");

    # step 5: remove previous ProtHint hints from hintsfile.gff
    print LOG "\# " . (localtime)
        . ": Removing first iteration ProtHint hints from "
        . "$otherfilesDir/hintsfile.gff\n" if ($v > 3);
    $cmdString = "mv $otherfilesDir/hintsfile.gff $otherfilesDir/hintsfile_iter1.gff";
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");
    open(HINTS1, "<", "$otherfilesDir/hintsfile_iter1.gff") or 
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to open file $otherfilesDir/hintsfile_iter1.gff!\n");
    open(HINTS2, ">", "$otherfilesDir/hintsfile.gff") or 
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to open file $otherfilesDir/hintsfile.gff!\n");
    while(<HINTS1>){
        if(not ($_ =~ m/\tProtHint\t/) ) {
            print HINTS2 $_;
        }
    }
    close(HINTS2) or 
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to close file $otherfilesDir/hintsfile.gff!\n");
    close(HINTS1) or 
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to close file $otherfilesDir/hintsfile_iter1.gff!\n");

    # step 6: add hints onto hintsfile.gff that need to go there
    print LOG "\# " . (localtime)
        . ": Appending hints from $otherfilesDir/evidence_augustus.gff to "
        . "$otherfilesDir/hintsfile.gff\n" if ($v > 3);
    open(HINTS, ">>", "$otherfilesDir/hintsfile.gff") or 
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to open file $otherfilesDir/hintsfile.gff!\n");
    # evidence_augustus.gff modified file
    open(EV_AUG, "<", "$otherfilesDir/evidence_augustus.gff") or 
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to open file $otherfilesDir/evidence_augustus.gff\n");
    while(<EV_AUG>){
        print HINTS $_;
    }
    close(EV_AUG) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to close file $otherfilesDir/evidence_augustus.gff\n");
    # modified top chains
    print LOG "\# " . (localtime)
        . ": Appending hints from $otherfilesDir/top_chains.gff to "
        . "$otherfilesDir/hintsfile.gff\n" if ($v > 3);
    open(TOP_CH, "<", "$otherfilesDir/top_chains.gff") or 
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to open file $otherfilesDir/top_chains.gff\n");
    while(<TOP_CH>){
        print HINTS $_;
    }
    close(TOP_CH) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to close file $otherfilesDir/top_chains.gff\n");
    # prothint_augustus.gff after logistic regression
    print LOG "\# " . (localtime)
        . ": Appending hints from $otherfilesDir/prothint_augustus.gff to "
        . "$otherfilesDir/hintsfile.gff\n" if ($v > 3);
    open(PHT, "<", "$otherfilesDir/prothint_augustus.gff") or 
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to open file $otherfilesDir/prothint_augustus.gff\n");
    while(<PHT>){
        print HINTS $_;
    }
    close(PHT) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to close file $otherfilesDir/prothint_augustus.gff\n");
    close(HINTS) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nfailed to close file $otherfilesDir/hintsfile.gff!\n");

    print LOG "\# " . (localtime)
        . ": Generating hints with ProtHint iteration 2 finished.\n" if ($v > 2);

}

####################### move_aug_preds #########################################
# * move:
#   augustus.hints.gtf -> augustus.hints_iter1.gtf
#   augustus.hints.aa -> augustus.hints_iter1.aa
#   augustus.hints.gff -> augustus.hints_iter1.gff
#   augustus.hints.codingseq -> augustus.hints_iter1.codingseq
################################################################################

sub move_aug_preds {
    print LOG "\# "
        . (localtime)
        . ": Moving augustus hints predictions from iteration 1\n" if ($v > 2);
    my @aug_files = ('augustus.hints.gtf', 'augustus.hints.gff', 
        'augustus.hints.aa', 'augustus.hints.codingseq');
    foreach(@aug_files){
        if(-e $otherfilesDir."/".$_){
            my $new_name = $_;
            $new_name =~ s/hints/hints_iter1/;
            $cmdString = "mv $otherfilesDir/$_ $otherfilesDir/$new_name";
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $cmdString!\n");
        }
    }
    if(-e $otherfilesDir.".braker.gtf"){
        my $new_name = "braker.iter1.gtf";
        $cmdString = "mv $otherfilesDir/braker.gtf $otherfilesDir/$new_name";
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nFailed to execute: $cmdString!\n");
    }
    if(-e $otherfilesDir."/Spaln/spaln.gff"){
        my $new_name = "spaln_iter1.gff";
        $cmdString = "mv $otherfilesDir/Spaln/spaln.gff $otherfilesDir/Spaln/$new_name";
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nFailed to execute: $cmdString!\n");
    }
    my @prot_hint_files = ('evidence.gff', 'evidence_augustus.gff', 'prothint.gff', 'prothint_augustus.gff');
    foreach(@aug_files){
        if(-e $otherfilesDir."/".$_){
            my $new_name = $_;
            $new_name =~ s/\.gff/_iter1\.gff/;
            $cmdString = "mv $otherfilesDir/$_ $otherfilesDir/$new_name";
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $cmdString!\n");
        }
    }
}


####################### make_rnaseq_hints ######################################
# * make hints from BAM files
# * merge hints files from different BAM files
# * add strand information to hint
################################################################################

sub make_rnaseq_hints {
    print LOG "\# "
        . (localtime)
        . ": Converting bam files to hints\n" if ($v > 2);

    print CITE $pubs{'samtools'}; $pubs{'samtools'} = "";
    print CITE $pubs{'bamtools'}; $pubs{'bamtools'} = "";

    # step 1: run augustus bam2hints in parallel
    my $bam_hints;
    my $hintsfile_temp = "$otherfilesDir/hintsfile.temp.gff";
    my $bam_temp; 
    my $pj = new Parallel::ForkManager($CPU);
    for ( my $i = 0; $i < scalar(@bam); $i++ ) {
        $errorfile = "$errorfilesDir/bam2hints.$i.stderr";
        $stdoutfile = "$errorfilesDir/bam2hints.$i.stdout";
        $bam_temp = "$otherfilesDir/bam2hints.temp.$i.gff";
        $bam[$i] = check_bam_headers( $bam[$i] );
        $augpath = "$AUGUSTUS_BIN_PATH/bam2hints";
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString .= "$augpath --intronsonly --in=$bam[$i] --out=$bam_temp 1> $stdoutfile 2>$errorfile";
        print LOG "\# "
            . (localtime)
            . ": make hints from BAM file $bam[$i]\n" if ($v > 3);
        print LOG "$cmdString\n" if ($v > 3);
        my $jid = $pj->start and next;
        system("$cmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $cmdString!\n");
        $pj->finish;
    }
    $pj->wait_all_children;
    # step 2: concatenate results of bam2hints (should not be run parallel)
    for ( my $i = 0; $i < scalar(@bam); $i++ ) {
        $bam_temp = "$otherfilesDir/bam2hints.temp.$i.gff";
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString .= "cat $bam_temp >>$hintsfile_temp";
        print LOG "\# "
            . (localtime)
            . ": add hints from BAM file $bam[$i] to hints file\n" if ($v > 3);
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nfailed to execute: $cmdString!\n");
        unlink($bam_temp);
    }
    if ( -f $hintsfile_temp || $overwrite ) {
        if ( !uptodate( [$hintsfile_temp], [$hintsfile] ) || $overwrite ) {
            join_mult_hints( $hintsfile_temp, "rnaseq" );
        }
        if ( !uptodate( [$hintsfile_temp], [$hintsfile] ) || $overwrite ) {
            $string = find(
                "filterIntronsFindStrand.pl", $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH,       $AUGUSTUS_CONFIG_PATH
            );
            $errorfile     = "$errorfilesDir/filterIntronsFindStrand.stderr";
            $perlCmdString = "";
            if ($nice) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString
                .= "perl $string $genome $hintsfile_temp --score 1>>$hintsfile 2>$errorfile"; # must append because otherwise ProtHint contents are overwritten
            print LOG "\# "
                . (localtime)
                . ": filter introns, find strand and change score to \'mult\' entry\n" if ($v > 3);
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nfailed to execute: $perlCmdString!\n");
            print LOG "\# " . (localtime) . ": rm $hintsfile_temp\n" if ($v > 3);
            unlink($hintsfile_temp);
        }
        if ( -z $hintsfile ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "The hints file is empty. Maybe the genome and the "
                . "RNA-seq file do not belong together.\n";
            print LOG $prtStr;
            clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                $prtStr);
        }
    }
}

####################### make_prot_hints ########################################
# * run protein to genome alignment (gth, spaln or exonerate if EPmode/ETPmode
#   == 0, or ProtHint if EPmode/ETPmode ==1 && prg == ph
# * convert alignments to hints (calls aln2hints)
# * converts GenomeThreader alignments to hints (calls gth2gtf)
################################################################################

sub make_prot_hints {
    print LOG "\# " . (localtime) . ": Making protein hints\n" if ($v > 2);
    my $prot_hints;
    my $prot_hints_file_temp = "$otherfilesDir/prot_hintsfile.temp.gff";
    $prot_hintsfile = "$otherfilesDir/prot_hintsfile.gff";
    my $alignment_outfile = "$otherfilesDir/protein_alignment_$prg.gff3";

    # change to working directory
    $cmdString = "cd $otherfilesDir";
    print LOG "\# " . (localtime) . ": Changing to $otherfilesDir\n" if ($v > 3);
    print LOG "$cmdString\n" if ($v > 3);
    chdir $otherfilesDir or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        ."\nFailed to execute $cmdString!\n");

    # from fasta files
    if ( @prot_seq_files && $EPmode == 0 && $ETPmode == 0) {
        $string = find(
            "startAlign.pl",        $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
        $errorfile = "$errorfilesDir/startAlign.stderr";
        $logfile   = "$otherfilesDir/startAlign.stdout";
        for ( my $i = 0; $i < scalar(@prot_seq_files); $i++ ) {
            if ( !uptodate( [ $prot_seq_files[$i] ], [$prot_hintsfile] )
                || $overwrite )
            {
                $perlCmdString = "";
                if ($nice) {
                    $perlCmdString .= "nice ";
                }
                $perlCmdString
                    .= "perl $string --genome=$genome --prot=$prot_seq_files[$i] --ALIGNMENT_TOOL_PATH=$ALIGNMENT_TOOL_PATH ";
                if ( $prg eq "gth" ) {
                    $perlCmdString .= "--prg=gth ";
                    print LOG "\# "
                        . (localtime)
                        . ": running Genome Threader to produce protein to "
                        . "genome alignments\n"  if ($v > 3);
                    print CITE $pubs{'gth'}; $pubs{'gth'} = "";
                }
                elsif ( $prg eq "exonerate" ) {
                    $perlCmdString .= "--prg=exonerate ";
                    print LOG "\# "
                        . (localtime)
                        . ": running Exonerate to produce protein to "
                        . "genome alignments\n" if ($v > 3);
                    print CITE $pubs{'exonerate'}; $pubs{'exonerate'} = "";
                }
                elsif ( $prg eq "spaln" ) {
                    $perlCmdString .= "--prg=spaln ";
                    print LOG "\# "
                        . (localtime)
                        . ": running Spaln to produce protein to "
                        . "genome alignments\n" if ($v > 3);
                    print CITE $pubs{'spaln'}; $pubs{'spaln'} = "";
                    print CITE $pubs{'spaln2'}; $pubs{'spaln2'} = "";
                }
                if ( $CPU > 1 ) {
                    $perlCmdString .= "--CPU=$CPU ";
                }
                if ($nice) {
                    $perlCmdString .= "--nice ";
                }
                $perlCmdString .= ">> $logfile 2>>$errorfile";
                print LOG "$perlCmdString\n" if ($v > 3);
                system("$perlCmdString") == 0
                    or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                     $useexisting, "ERROR in file " . __FILE__ ." at line "
                     . __LINE__ ."\nfailed to execute: $perlCmdString!\n");
                print LOG "\# "
                    . (localtime)
                    . ": Alignments from file $prot_seq_files[$i] created.\n" if ($v > 3);
                if ( -s "$otherfilesDir/align_$prg/$prg.concat.aln" ) {
                    $cmdString
                        = "cat $otherfilesDir/align_$prg/$prg.concat.aln >> $alignment_outfile";
                    print LOG "\# "
                        . (localtime)
                        . ": concatenating alignment file to $alignment_outfile\n" if ($v > 3);
                    print LOG "$cmdString\n" if ($v > 3);
                    system("$cmdString") == 0
                        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                            $useexisting, "ERROR in file " . __FILE__
                            . " at line ". __LINE__
                            . "\nFailed to execute $cmdString!\n");
                }
                else {
                    print LOG "\# " . (localtime) . ": alignment file "
                        . "$otherfilesDir/align_$prg/$prg.concat.aln in round $i "
                        . "was empty.\n" if ($v > 3);
                }
                print LOG "\# "
                    . (localtime)
                    . ": moving startAlign output files\n" if ($v > 3);
                $cmdString = "mv $otherfilesDir/align_$prg $otherfilesDir/align_$prg$i";
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0
                    or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                        $useexisting, "ERROR in file " . __FILE__ ." at line "
                        . __LINE__ ."\nFailed to execute: $cmdString!\n");
            }
            else {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Skipping running alignment tool "
                    . "because files $prot_seq_files[$i] and $prot_hintsfile "
                    . "were up to date.\n";
                print LOG $prtStr if ($v > 3);
            }
        }
    }
    # the following is accomplished further up
    #elsif ( @prot_seq_files && ( $EPmode == 1 or $ETPmode == 1)) {
        # run_prothint();
    #}

    # convert pipeline created protein alignments to protein hints
    if ( @prot_seq_files && -e $alignment_outfile ) {
        if ( !uptodate( [$alignment_outfile], [$prot_hintsfile] )
            || $overwrite )
        {
            if ( -s $alignment_outfile && $EPmode == 0 && $ETPmode == 0) {
                aln2hints( $alignment_outfile, $prot_hints_file_temp );
            }
            elsif ( -s $alignment_outfile && ($EPmode == 1||$ETPmode==1) ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "Conversion of ProSplign alignments within "
                    . "braker.pl is currently not supported. To run braker.pl with "
                    . "GeneMark-EP/-ETP, please provide --hints=intronhints.gff! Aborting "
                    . "braker.pl!\n";
                print LOG $prtStr;
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, $prtStr);
            }
            else {
                print LOG "\# "
                    . (localtime)
                    . ": Alignment out file $alignment_outfile with "
                    . "protein alignments is empty. Not producing any hints "
                    . "from protein input sequences.\n" if ($v > 3);
            }
        }
    }

    # convert command line specified protein alignments to protein hints
    if ( @prot_aln_files && $EPmode == 0 && $ETPmode == 0) {
        for ( my $i = 0; $i < scalar(@prot_aln_files); $i++ ) {
            if ( !uptodate( [ $prot_aln_files[$i] ], [$prot_hintsfile] )
                || $overwrite )
            {
                aln2hints( $prot_aln_files[$i], $prot_hints_file_temp );
            }
            else {
                print LOG "\# "
                    . (localtime)
                    . ": Skipped converting alignment file "
                    . "$prot_aln_files[$i] to hints because it was up to date "
                    . "with $prot_hintsfile\n" if ($v > 3);
            }
        }
    }
    elsif ( @prot_aln_files && ($EPmode == 1 || $ETPmode == 1)) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "Conversion of ProSplign alignments within "
            . "braker.pl is currently not supported. Aborting braker.pl!\n";
        print LOG $prtStr;
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting, $prtStr);
    }

    # appending protein hints to $hintsfile (combined with RNA_Seq if available)
    if ( ( -f $prot_hints_file_temp || $overwrite ) && $EPmode == 0 && $ETPmode == 0) {
        if ( !uptodate( [$prot_hints_file_temp], [$prot_hintsfile] )
            || $overwrite )
        {
            join_mult_hints( $prot_hints_file_temp, "prot" );
            print LOG "\# "
                . (localtime)
                . ": moving $prot_hints_file_temp to $prot_hintsfile\n" if ($v > 3);
            $cmdString = "mv $prot_hints_file_temp $prot_hintsfile";
            print LOG "$cmdString\n" if ($v > 3);
            system($cmdString) == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $cmdString!\n");
            print LOG "Deleting $prot_hints_file_temp\n" if ($v > 3);
            unlink($prot_hints_file_temp);
            print LOG "\# "
                . (localtime)
                . ": joining protein and RNA-Seq hints files -> appending "
                . "$prot_hintsfile to $hintsfile\n" if ($v > 3);
            $cmdString = "cat $prot_hintsfile >> $hintsfile";
            print LOG "$cmdString\n" if ($v > 3);
            system($cmdString) == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $cmdString!\n");
            print LOG "\# " . (localtime) . ": Deleting $prot_hintsfile\n" if ($v > 3);
            unlink($prot_hintsfile);
            my $toBeSortedHintsFile = "$otherfilesDir/hintsfile.tmp.gff";
            print LOG "\# "
                . (localtime)
                . ": Moving $hintsfile to $toBeSortedHintsFile to enable "
                . "sorting\n" if ($v > 3);
            $cmdString = "mv $hintsfile $toBeSortedHintsFile";
            print LOG "$cmdString\n" if ($v > 3);
            system($cmdString) == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $cmdString!\n");
            print LOG "\# "
                . (localtime)
                . ": Sorting hints file $hintsfile\n" if ($v > 3);
            $cmdString
                = "cat $toBeSortedHintsFile | sort -n -k 4,4 | sort -s -n -k 5,5 | sort -s -n -k 3,3 | sort -s -k 1,1 > $hintsfile";
            print LOG "$cmdString\n" if ($v > 3);
            system($cmdString) == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $cmdString!\n");
            print LOG "\# "
                . (localtime)
                . ": Deleting file $toBeSortedHintsFile\n" if ($v > 3);
            print LOG "rm $toBeSortedHintsFile\n" if ($v > 3);
            unlink($toBeSortedHintsFile);
        }
    }
    if ( -z $prot_hintsfile && $EPmode == 0 && $ETPmode == 0 ) {
        $prtStr
            = "\# "
            . (localtime)
            . " ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "The hints file is empty. There were no protein "
            . "alignments.\n";
        print LOG $prtStr;
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            $prtStr);
    }
    if ($gth2traingenes) {
        if (@prot_aln_files) {
            foreach (@prot_aln_files) {
                $cmdString = "cat $_ >> $alignment_outfile";
                print LOG "\# "
                    . (localtime)
                    . ": Concatenating protein alignment input file $_ to "
                    . "$alignment_outfile\n" if ($v > 3);
                print LOG "$cmdString\n" if ($v > 3);
                system($cmdString) == 0
                    or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                        $useexisting, "ERROR in file " . __FILE__ ." at line "
                        . __LINE__ ."\nFailed to execute: $cmdString!\n");
            }
        }
        gth2gtf( $alignment_outfile, $gthTrainGeneFile );
    }
}

####################### aln2hints ##############################################
# * converts protein alignments to hints
################################################################################

sub aln2hints {
    my $aln_file = shift;
    print LOG "\# " . (localtime)
        . ": Converting alignments from file $aln_file to hints\n" if ($v > 2);
    if ( !( -z $aln_file ) ) {
        my $out_file_name
            = "$otherfilesDir/prot_hintsfile.aln2hints.temp.gff";
        my $final_out_file = shift;
        print LOG "\# "
            . (localtime)
            . ": Converting protein alignment file $aln_file to hints for "
            . "AUGUSTUS\n" if ($v > 3);
        $perlCmdString = "perl ";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $string = find(
            "align2hints.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $perlCmdString .= "$string --in=$aln_file --out=$out_file_name ";
        if ( $prg eq "spaln" ) {
            $perlCmdString .= "--prg=spaln";
        }
        elsif ( $prg eq "gth" ) {
            $perlCmdString .= "--prg=gth --priority=5";
        }
        elsif ( $prg eq "exonerate" ) {
            $perlCmdString
                .= "--prg=exonerate --genome_file=$genome --priority=3";
        }
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $perlCmdString\n");
        $cmdString = "cat $out_file_name >> $final_out_file";
        print LOG "\# "
            . (localtime)
            . ": concatenating protein hints from $out_file_name to "
            . "$final_out_file\n" if ($v > 3);
        print LOG $cmdString . "\n" if ($v > 3);
        system("$cmdString") == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
    }
    else {
        print LOG "#*********\n"
                . "# WARNING: Alignment file $aln_file was empty!\n"
                . "#*********\n" if ($v > 0);
    }
}

####################### gth2gtf ################################################
# * converts GenomeThreader alignments to gtf for training AUGUSTUS
################################################################################

sub gth2gtf {
    my $align = shift;
    print LOG "\# " . (localtime) . ": Converting GenomeThreader file $align "
    . "to gtf format\n" if ($v > 2);
    my $out   = shift;    # writes to $gthTrainGeneFile
    open( GTH,    "<", $align ) or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $align!\n");
    open( GTHGTF, ">", $out )   or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $out!\n");
    my $geneId;

    # GTH may output alternative transcripts; we don't want to have any
    # alternatives in training gene set, only print the first of any occuring
    # alternatives
    my %seen;
    while (<GTH>) {
        chomp;
        my @gtfLine = split(/\t/);
        if (m/\tgene\t/) {
            my @idCol = split( /=/, $gtfLine[8] );
            $geneId = $idCol[1];
        }
        elsif (m/\tCDS\t/) {
            my @gtfLineLastCol      = split( /;/, $gtfLine[8] );
            my @gtfLineLastColField = split( /=/, $gtfLineLastCol[1] );
            if (not( defined( $seen{ "$gtfLine[0]" . "_" . $geneId . "_" } ) )
                )
            {
                $seen{ "$gtfLine[0]" . "_" . $geneId . "_" }
                    = "$gtfLine[0]" . "_"
                    . $geneId . "_"
                    . $gtfLineLastColField[1];
            }
            if ( $seen{ "$gtfLine[0]" . "_" . $geneId . "_" } eq "$gtfLine[0]"
                . "_"
                . $geneId . "_"
                . $gtfLineLastColField[1] )
            {
                print GTHGTF "$gtfLine[0]\t$gtfLine[1]\t$gtfLine[2]\t"
                            . "$gtfLine[3]\t$gtfLine[4]\t$gtfLine[5]\t"
                            . "$gtfLine[6]\t$gtfLine[7]\tgene_id \""
                            . "$gtfLine[0]_g_" .$geneId . "_"
                            . $gtfLineLastColField[1] . "\"; transcript_id "
                            . "\"$gtfLine[0]_t" . "_" . $geneId . "_"
                            . $gtfLineLastColField[1] . "\";\n";
                print GTHGTF "$gtfLine[0]\t$gtfLine[1]\texon\t$gtfLine[3]\t"
                            . "$gtfLine[4]\t$gtfLine[5]\t$gtfLine[6]\t"
                            . "$gtfLine[7]\tgene_id \"$gtfLine[0]_g" . "_"
                            . $geneId . "_"
                            . $gtfLineLastColField[1] . "\"; transcript_id \""
                            . "$gtfLine[0]_t" . "_" . $geneId . "_"
                            . $gtfLineLastColField[1] . "\";\n";
            }
        }
    }
    close(GTHGTF) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $out!\n");
    close(GTH)    or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $align!\n");
}

####################### add_other_hints ########################################
# * add command line supplied hints to hints file
################################################################################

sub add_other_hints {
    print LOG "\# " . (localtime)
        . ": Adding other user provided hints to hintsfile\n" if ($v > 2);
    if (@hints) {
        # have "uptodate" issues at this point, removed it... maybe fix later
        for ( my $i = 0; $i < scalar(@hints); $i++ ) {
            # replace Intron by intron
            my $replacedHintsFile = "$otherfilesDir/replaced_hints_$i.gff";
            open (OTHER, "<", $hints[$i]) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not open file $hints[$i]!\n");
            open (REPLACED, ">", $replacedHintsFile) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not open file $replacedHintsFile!\n");
            while(<OTHER>) {
                $_ =~ s/\tIntron\t/\tintron\t/;
                print REPLACED $_;
            }
            close (OTHER) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not close file $hints[$i]!\n");
            close (REPLACED) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not close file $replacedHintsFile!\n");
            # find Strand, set multiplicity for GeneMark
            my $filteredHintsFile = "$otherfilesDir/filtered_hints_$i.gff";
            $string = find(
                "filterIntronsFindStrand.pl", $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH,       $AUGUSTUS_CONFIG_PATH
            );
            $errorfile = "$errorfilesDir/filterIntronsFindStrand_userHints_$i.stderr";
            $perlCmdString = "";
            if ($nice) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString .= "perl $string $genome $replacedHintsFile --score 1> $filteredHintsFile 2>$errorfile";
            print LOG "\# "
                . (localtime)
                . ": filter introns, find strand and change score to \'mult\' "
                . "entry\n" if ($v > 3);
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nfailed to execute: $perlCmdString!\n");
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "cat $filteredHintsFile >> $hintsfile";
            print LOG "\# "
                . (localtime)
                . ": adding hints from file $filteredHintsFile to $hintsfile\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $cmdString!\n");
            print LOG "\# "
                . (localtime)
                . ": deleting file $filteredHintsFile\n" if ($v > 3);
            unlink ( $filteredHintsFile ) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to delete file $filteredHintsFile!\n");
            print LOG "\# "
                . (localtime)
                . ": deleting file $replacedHintsFile\n" if ($v > 3);
            unlink ( $replacedHintsFile ) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to delete file $replacedHintsFile!\n");;
        }
        join_mult_hints( $hintsfile, "all" );
    }
}

####################### join_mult_hints ########################################
# * joins hints that are identical (from the same source)
# * hints with src=C and grp= tags are not joined
################################################################################

sub join_mult_hints {
    my $hints_file_temp = shift;
    my $type            = shift;    # rnaseq or prot or whatever will follow
    print LOG "\# " . (localtime) . ": Checking for hints of src=C and with grp "
        . "tags that should not be joined according to multiplicity\n" if ($v > 2);
    my $to_be_merged = $otherfilesDir."/tmp_merge_hints.gff";
    my $not_to_be_merged = $otherfilesDir."/tmp_no_merge_hints.gff";
    open(HINTS, "<", $hints_file_temp) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to open file $hints_file_temp for reading!\n");
    open(MERG, ">", $to_be_merged) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to open file $to_be_merged for writing!\n");
    open(NOME, ">", $not_to_be_merged) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to open file $not_to_be_merged for writing!\n");
    while(<HINTS>){
        if($_ =~ m/src=C/ && (($_ =~ m/grp=/) || $_ =~ m/group=/)){
            print NOME $_;
        }else{
            print MERG $_;
        }
    }
    close(MERG) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to close file $to_be_merged!\n");
    close(NOME) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to close file $not_to_be_merged!\n");
    close(HINTS) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to open file $hints_file_temp for reading!\n");
    if(-z $to_be_merged){
        unlink($to_be_merged);
        $cmdString = "mv $not_to_be_merged $hints_file_temp";
        print LOG "$cmdString\n" if ($v > 3);
        system($cmdString) == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
    }else{
        print LOG "\# " . (localtime) . ": Joining hints that are identical "
            . "(& from the same source) into multiplicity hints (input file "
            . "$to_be_merged)\n" if ($v > 2);        
        my $hintsfile_temp_sort = "$otherfilesDir/hints.$type.temp.sort.gff";
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString .= "cat $to_be_merged | sort -n -k 4,4 | sort -s -n -k 5,5 | sort -s -n -k 3,3 | sort -s -k 1,1 >$hintsfile_temp_sort";
        print LOG "\# " . (localtime) . ": sort hints of type $type\n" if ($v > 3);
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or clean_abort(
           "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString!\n");
        $string = find(
            "join_mult_hints.pl",   $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $errorfile     = "$errorfilesDir/join_mult_hints.$type.stderr";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string <$hintsfile_temp_sort >$to_be_merged 2>$errorfile";
        print LOG "\# " . (localtime) . ": join multiple hints\n" if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nFailed to execute: $perlCmdString\n");
        unlink($hintsfile_temp_sort);
    }
    if( -z $not_to_be_merged ) {
        $cmdString = "mv $to_be_merged $hints_file_temp";
        print LOG "$cmdString\n" if ($v > 3);
        system($cmdString) == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
    }else{
        $cmdString = 'cat '.$to_be_merged.' '.$not_to_be_merged.' > '.$hints_file_temp;
        print LOG "$cmdString\n" if ($v > 3);
        system($cmdString) == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
    }
}

####################### check_hints ############################################
# * check whether hints file contains hints from RNA-Seq (returns 1)
# * check whether hints file contains hints from proteins ($foundProt++)
################################################################################

sub check_hints {
    $prtStr = "\# ". (localtime)
            . ": Checking whether hints from RNA-Seq and/or proteins are "
            . "present in hintsfile\n";
    $logString .= $prtStr if ($v > 2);
    my $thisHintsFile = shift;
    my @areb2h        = `cut -f 9 $thisHintsFile | grep src=E`;
    my $ret           = 0;
    if ( scalar( @areb2h ) > 0 ) {
        $ret = 1;
    }
    my @areP = `cut -f 9 $thisHintsFile | grep src=P`;
    if( scalar( @areP ) > 0 ) {
        $foundProt++;
    }
    return $ret;
}

####################### get_genemark_hints #####################################
# * GeneMark only uses intron hints, AUGUSTUS also uses other hints types
# * this function creates $genemark_hintsfile with intron hints
# * Scenarios: 
#      - EPmode - do nothing, instead use prothint.gff and evidence.gff
#      - ETmode - do nothing, should be intron hints only?
#      - ETPmode - append prothint.gff and 
#                  RNA-Seq intron hints to genemark_hints.gff,
#                  append prot & RNA-Seq evidence to evidence.gff
################################################################################


sub get_genemark_hints {
    print LOG "\# ". (localtime) . ": Preparing hints for running GeneMark\n" if ($v > 2);
    # temporary files
    my $gm_hints_rnaseq = "$genemark_hintsfile.rnaseq";
    my $gm_hints_prot = "$genemark_hintsfile.prot";

    # filter intron hints from original hintsfile and separate into
    # protein and rnaseq hints file
    print LOG "\# " . (localtime)
        . ": Filtering intron hints for GeneMark from $hintsfile...\n" if ($v > 3);
    open (HINTS, "<", $hintsfile) or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $hintsfile!\n");
    open (OUTRNASEQ, ">", $gm_hints_rnaseq) or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $gm_hints_rnaseq!\n");
    open (OUTPROT, ">", $gm_hints_prot) or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $gm_hints_prot!\n");
    my $warnProt = 0;
    while (<HINTS>) {
        if ( $_ =~ m/\tintron\t/i && ($_ =~ m/src=E/) ) {
            $_ =~ s/intron/Intron/;
            print OUTRNASEQ $_;
        }elsif ( $_ =~ m/\tintron\t/i && ($_ =~ m/src=P/) ) {
            $_ =~ s/intron/Intron/;
            if(not(defined($prothint_file))){
                print OUTPROT $_;
            }elsif( ($EPmode == 1 || $ETPmode == 1) && defined($prothint_file) && $warnProt == 0) {
                $prtStr = "WARNING: protein hints from "
                        . "file $hintsfile, are ignored because "
                        . "they are assumed to be duplicates of "
                        . "hints provided in ProtHint file $prothint_file"
                        . " if BRAKER is run in EP or ETP mode!\n";
                print LOG $prtStr;
                $warnProt = 1;
            }
        }
    }
    close (OUTRNASEQ) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $gm_hints_rnaseq!\n");
    close (HINTS) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $hintsfile!\n");
    close (OUTPROT) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $gm_hints_prot!\n");

    if ( -s $gm_hints_rnaseq ) {
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $string = find(
            "join_mult_hints.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $cmdString .= "cat $gm_hints_rnaseq | sort -n -k 4,4 | sort -s -n -k 5,5 | sort -s -k 3,3 | sort -s -k 1,1 | $string > $gm_hints_rnaseq.tmp";
        print LOG "$cmdString\n" if ($v > 3);
        system($cmdString) == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
    }

    if( -s $gm_hints_prot ) {
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $string = find(
            "join_mult_hints.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $cmdString .= "cat $gm_hints_prot | sort -n -k 4,4 | sort -s -n -k 5,5 | sort -s -k 3,3 | sort -s -k 1,1 | $string > $gm_hints_prot.tmp";
        print LOG "$cmdString\n" if ($v > 3);
        system($cmdString) == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
    }

    if( $EPmode == 0 && not($skipAllTraining)) {
        $cmdString = "mv $gm_hints_rnaseq.tmp $genemark_hintsfile";
        print LOG "$cmdString\n" if ($v > 3);
        system($cmdString) == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
    }

    if( -e $gm_hints_rnaseq ) {
            unlink ($gm_hints_rnaseq) or clean_abort(
                "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                "ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete file $gm_hints_rnaseq\n");
    }
    if( -e $gm_hints_prot ) {
        unlink ($gm_hints_prot) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to delete file $gm_hints_prot\n");
    }
    if( -e "$gm_hints_prot.tmp"){
        unlink ("$gm_hints_prot.tmp") or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to delete file $gm_hints_prot.tmp\n");
    }
    if( -e "$gm_hints_rnaseq.tmp"){
        unlink ("$gm_hints_rnaseq.tmp") or clean_abort (
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to delete file $gm_hints_rnaseq.tmp\n");
    }
}

####################### format_ep_hints ########################################
# * format output from Atlanta protein mapping pipeline for AUGUSTUS and
#   GeneMark, i.e. replace Intron by intron, set last column fields src/mult/pri
#   for AUGUSTUS
# * this function can be deleted once the output format of the mapping pipeline
#   is natively compatible
################################################################################

sub format_ep_hints {
    print LOG "\# "
        . (localtime)
        . ": Reformating hints file for GeneMark-E(T)P and AUGUSTUS\n" if ($v > 2);
    open( INTRONS, "<", $genemark_hintsfile )
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $genemark_hintsfile!\n");
    open( OUT, ">", "$otherfilesDir/tmp.hints" )
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $otherfilesDir/tmp.hints!\n");
    while (<INTRONS>) {
        my @t = split(/\t/);
        print OUT "$t[0]\t$t[1]\t$t[2]\t$t[3]\t$t[4]\t$t[5]\t$t[6]\t$t[7]\t";
        if ($t[8] =~ m/Parent=/){
            if ( $t[5] == 1 ) {
                print OUT "pri=4;";
                if($t[7] =~ m/src=([^;])/){
                    print OUT "src=".$1."\n";
                }else{
                    print OUT "src=P\n";
                }
            } else {
                print OUT "mult=$t[5];pri=4;";
                if($t[7] =~ m/src=([^;])/){
                    print OUT "src=".$1."\n";
                }else{
                    print OUT "src=P\n";
                }
            }
        }elsif( $t[8] =~ m/so?u?rce?=/){
            if(not($_ =~ m/prio?r?i?t?y?=/)){
                print OUT "pri=4;"
            }
            if(not($_=~ m/mult=/) && not ($_ =~ m/gro?u?p=/)){
                print OUT "mult=$t[5];"
            }
            print OUT $t[8];
        }elsif( not ( $t[8] =~ m/so?u?rce?=/) ) {
            $prtStr = "#*********\n"
                    . "# WARNING: Format of hintsfile $genemark_hintsfile is "
                    . "incorrect in the last column, possibly src="
                    . "tag is missing!\n$t[8]"
                    . "#*********\n";
            print STDOUT $prtStr;
            print LOG $prtStr;
        }
    }
    close (OUT) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $otherfilesDir/tmp.hints!\n");
    close(INTRONS) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $genemark_hintsfile!\n");
    $cmdString = "mv $otherfilesDir/tmp.hints $genemark_hintsfile";
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0 or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString\n");
}

####################### create_evidence_gff ####################################
# * evidence.gff file is now produced by ProtHint
# * additional high quality hints can be added to that file by combining
#   RNA-Seq and prothint_augustus.gff hints
# * such hints are also appended with src=M to hintsfile for AUGUSTUS
################################################################################

sub create_evidence_gff {
    print LOG "\# " . (localtime) . ": Extending evidence.gff by hints from both "
        . "RNA-Seq and proteins...\n" if ($v > 2);
    # $evidence exists
    my %rnaseq;
    my %prot;
    my %manual;
    my $manualExists = 0;
    # $hintsfile exists

    # 1) extend append hints that should have src=M to hintsfile for AUGUSTUS
    open ( HINTS, "<", $otherfilesDir."/hintsfile.gff" ) or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $otherfilesDir"."/hintsfile.gff!\n");
    while (<HINTS>) {
        if($_ =~ m/(\S+)\t(\S+)\t(\S+)\t(\d+)\t(\d+)\t(\S+)\t(\S+)\t(\S+)\t(.*)/){
            my %hint;
            $hint{'locus'} = $1;
            $hint{'source'} = $2;
            $hint{'feature'} = $3;
            $hint{'start'} = $4;
            $hint{'stop'} = $5;
            $hint{'score'} = $6;
            $hint{'strand'} = $7;
            $hint{'frame'} = $8;
            $hint{'lastCol'} = $9;
            if( $9 =~ m/src=P/) {
                push ( @{$prot{$hint{'locus'}}}, \%hint);
            }elsif ( $9 =~ m/src=E/ ) {
                push (@{$rnaseq{$hint{'locus'}}}, \%hint);
            }elsif( $9 =~ m/src=M/ ) {
                push (@{$manual{$hint{'locus'}}}, \%hint);
                $manualExists = 1; # could also be tested by computing size of %manual contents
            }
        }
    }
    close(HINTS) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $otherfilesDir"."/hintsfile.gff!\n");

    open( EVAUG, ">>", $otherfilesDir."/hintsfile.gff") or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $otherfilesDir"."/hintsfile.gff!\n");
    foreach my $locus (keys %rnaseq) {
        if( defined ($prot{$locus}) ) {
            foreach my $hint (@{$rnaseq{$locus}}) {
                foreach my $otherHint (@{$prot{$locus}}) {
                    if( $hint->{'start'} == $otherHint->{'start'} && $hint->{'stop'} == $otherHint->{'stop'} && $hint->{'strand'} eq $otherHint->{'strand'} ) {
                        print EVAUG $locus."\tboth\t".$hint->{'feature'}."\t".$hint->{'start'}."\t".$hint->{'stop'}
                            ."\t1000\t".$hint->{'strand'}."\t".$hint->{'frame'}."\tsrc=M;pri=6;\n";
                    }
                }
            }
        }
    }
    close(EVAUG) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $otherfilesDir/hintsfile.gff!\n");
   
    # 2) extend evidence.gff file for GeneMark
    if(-e $otherfilesDir."/evidence.gff"){
        open( EV, ">>", $otherfilesDir."/evidence.gff") or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $otherfilesDir"."/evidence.gff!\n");
    }else{
        open( EV, ">", $otherfilesDir."/evidence.gff") or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $otherfilesDir"."/evidence.gff!\n");
    }
    foreach my $locus (keys %rnaseq) {
        if( defined ($prot{$locus}) ) {
            foreach my $hint (@{$rnaseq{$locus}}) {
                foreach my $otherHint (@{$prot{$locus}}) {
                    if( $hint->{'start'} == $otherHint->{'start'} && $hint->{'stop'} == $otherHint->{'stop'} && $hint->{'strand'} eq $otherHint->{'strand'} ) {
                        print EV $locus."\tboth\t".$hint->{'feature'}."\t".$hint->{'start'}."\t".$hint->{'stop'}
                            ."\t1000\t".$hint->{'strand'}."\t".$hint->{'frame'}."\tsrc=M;pri=6;\n";
                    }
                }
            }
        }
    }
    close(EV) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $otherfilesDir/evidence.gff!\n");
}

####################### append_prothint_to_genemark_hints ######################
# * append prothint file to genemark_hintsfile (with RNA-Seq hints for 
#   GeneMark-ETP)
################################################################################
sub append_prothint_to_genemark_hints{
    print LOG "\# " . (localtime) . ": Appending contents for ProtHint output to "
        . "$otherfilesDir/genemark_hintsfile.gff (that already contains RNA-Seq "
        . "hints)...\n" if ($v > 2);
    open(GH, ">>", $otherfilesDir."/genemark_hintsfile.gff") or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $otherfilesDir"."/genemark_hintsfile.gff!\n");
    open(PH, "<", $otherfilesDir."/prothint.gff") or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $otherfilesDir/prothint.gff!\n");
    while(<PH>){
        print GH $_;
    }
    close(PH) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $otherfilesDir/prothint.gff!\n");
    close(GH) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $otherfilesDir"."/genemark_hintsfile.gff!\n");
}

####################### check_genemark_hints ###################################
# * low intron coverage / few hints may cause GeneMark to crash
# * thresholds to report warning are kind or arbitrarily chosen
# * it is planned that GeneMark will set appropriate thresholds based on
#   individual data sets
################################################################################

sub check_genemark_hints {
    my $nIntrons               = 0;
    my $nIntronsAboveThreshold = 0;
    if ( $EPmode == 1 || $ETPmode == 1 ) {
        $GeneMarkIntronThreshold = 4;
    }
    else {
        $GeneMarkIntronThreshold = 10;
    }
    if( ($EPmode == 0 && $ETPmode==0 && $ESmode == 0) || $ETPmode == 1 ) { 
        print LOG "\# "
            . (localtime)
            . ": Checking whether file $genemark_hintsfile contains "
            . "sufficient multiplicity information...\n" if ($v > 2);
        open( GH, "<", $genemark_hintsfile )
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                "ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nCould not open file $genemark_hintsfile!\n");
        while (<GH>) {
            my @line = split(/\t/);
            if ( scalar(@line) == 9 ) {
                $nIntrons++;
                if ( $line[5] =~ m/(\d+)/ ) {
                    if ( $1 >= $GeneMarkIntronThreshold ) {
                        $nIntronsAboveThreshold++;
                    }
                }
            }
        }
        close(GH) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $genemark_hintsfile!\n");
    }elsif( $EPmode == 1 ) {
        print LOG "\# " . (localtime)
            . ": Checking whether file $otherfilesDir/prothint.gff and $otherfilesDir/evidence.gff contains "
            . "sufficient multiplicity information...\n" if ($v > 2);
        open( PH, "<", $otherfilesDir."/prothint.gff" )
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                "ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nCould not open file $otherfilesDir/prothint.gff!\n");
        while (<PH>) {
            my @line = split(/\t/);
            if ( scalar(@line) == 9 ) {
                $nIntrons++;
                if ( $line[5] =~ m/(\d+)/ ) {
                    if ( $1 >= $GeneMarkIntronThreshold ) {
                        $nIntronsAboveThreshold++;
                    }
                }
            }
        }
        close(PH) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $prothint_file!\n");
        open( EV, "<", $otherfilesDir."/evidence.gff" )
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                "ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nCould not open file $otherfilesDir/evidence.gff!\n");
        while (<EV>) {
            my @line = split(/\t/);
            if ( scalar(@line) == 9 ) {
                $nIntrons++;
                if ( $line[5] =~ m/(\d+)/ ) {
                    if ( $1 >= $GeneMarkIntronThreshold ) {
                        $nIntronsAboveThreshold++;
                    }
                }
            }
        }
        close(EV) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $otherfilesDir/evidence.gff!\n");
    }
    if ( $nIntronsAboveThreshold < 150 ) {
        $prtStr = "#*********\n"
                . "# WARNING: \n"
                . "# The hints file(s) for GeneMark-EX contain less than 150 "
                . "introns with multiplicity >= $GeneMarkIntronThreshold! (In "
                . "total, $nIntrons unique introns are contained. "
                .  "$nIntronsAboveThreshold have a multiplicity >= 10.) Possibly, you "
                . "are trying to run braker.pl on data that does not provide sufficient "
                . "multiplicity information. This will e.g. happen if you try to "
                . "use introns generated from assembled RNA-Seq transcripts; or if "
                . "you try to run braker.pl in epmode with mappings from proteins "
                . "without sufficient hits per locus. Or if you use the example data"
                . " set (orthodb_small.fa).\n"
                . "# A low number of intron hints with sufficient multiplicity may "
                . "result in a crash of GeneMark-EX (it should not crash with the "
                . "example data set).\n"
                . "#*********\n";
        print LOG $prtStr if ($v > 0);
        print STDOUT $prtStr;
    }
}

####################### GeneMark_ES ############################################
# * execute GeneMark-ES
################################################################################

sub GeneMark_ES {
    print LOG "\# " . (localtime) . ": Executing GeneMark-ES\n" if ($v > 2);
    my $localGenemarkDir = shift;
    if ( !$skipGeneMarkET ) {
        if (!uptodate( [ $genome], ["$localGenemarkDir/genemark.gtf"] ) || $overwrite
            ){
            $cmdString = "cd $localGenemarkDir";
            print LOG "\# "
                . (localtime)
                . ": changing into GeneMark-ES directory $localGenemarkDir\n"
                if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            chdir $localGenemarkDir
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__
                    ."\nCould not change into directory $localGenemarkDir.\n");
            $string        = "$GENEMARK_PATH/gmes_petap.pl";
            $errorfile     = "$errorfilesDir/GeneMark-ES.stderr";
            $stdoutfile    = "$otherfilesDir/GeneMark-ES.stdout";
            $perlCmdString = "";

            if ($nice) {
                $perlCmdString .= "nice ";
            }

            # consider removing --verbose, later
            $perlCmdString
                .= "perl $string --verbose --cores=$CPU --ES --gc_donor $gc_prob";
            if(defined($transmasked_fasta)){
                  $perlCmdString .= " --sequence=$transmasked_fasta ";
            }else{
                  $perlCmdString .= " --sequence=$genome ";
            }
            if ($fungus) {
                $perlCmdString .= " --fungus";
                print CITE $pubs{'gm-fungus'}; $pubs{'gm-fungus'} = "";
            }
            if ($soft_mask) {
                $perlCmdString .= " --soft_mask auto";
                      # version prior to 4.29, apparently also in version 4.33
                      #     $perlCmdString .= " --soft 1000"; # version 4.29
            }
            if (defined($min_contig)) {
                  $perlCmdString .= " --min_contig=10000";
            }
            $perlCmdString .= " 1>$stdoutfile 2>$errorfile";
            print LOG "\# " . (localtime) . ": Executing gmes_petap.pl\n" 
                if ($v > 3);
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $perlCmdString\n"
                    . "The most common problem is an expired or not "
                    . "present file ~/.gm_key!\n");
            $cmdString = "cd $rootDir";
            print LOG "\# "
                . (localtime)
                . ": change to working directory $rootDir\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            chdir $rootDir
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not change to directory $rootDir.\n");
        } else {
            print LOG "\# " . (localtime) . ": skipping GeneMark-ES because "
                . "$localGenemarkDir/genemark.gtf is up to date.\n" if ($v > 3);
        }
    }
}

####################### GeneMark_ET ############################################
# * execute GeneMark-ET with RNA-Seq hints for training
################################################################################

sub GeneMark_ET {
    print LOG "\# " . (localtime) . ": Executing GeneMark-ET\n" if ($v > 2);
    
    print CITE $pubs{'gm-et'}; $pubs{'gm-et'} = "";

    if ( !$skipGeneMarkET ) {
        if (!uptodate( [ $genome, $genemark_hintsfile ], 
            ["$genemarkDir/genemark.gtf"] ) || $overwrite ) {
            $cmdString = "cd $genemarkDir";
            print LOG "\# "
                . (localtime)
                . ": changing into GeneMark-ET directory $genemarkDir\n"
                if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            chdir $genemarkDir
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__
                    ."\nCould not change into directory $genemarkDir.\n");
            $string        = "$GENEMARK_PATH/gmes_petap.pl";
            $errorfile     = "$errorfilesDir/GeneMark-ET.stderr";
            $stdoutfile    = "$otherfilesDir/GeneMark-ET.stdout";
            $perlCmdString = "";

            if ($nice) {
                $perlCmdString .= "nice ";
            }

            # consider removing --verbose, later
            $perlCmdString .= "perl $string --verbose ";
            if(defined($transmasked_fasta)){
                  $perlCmdString .= "--sequence=$transmasked_fasta ";
            }else{
                  $perlCmdString .= "--sequence=$genome ";
            }
            if(defined($min_contig)){
                  $perlCmdString .= "--min_contig=$min_contig ";
            }
            $perlCmdString .= "--ET=$genemark_hintsfile --et_score 10 "
                           .  "--max_intergenic 50000 --cores=$CPU --gc_donor $gc_prob";
            if ($fungus) {
                $perlCmdString .= " --fungus";
                print CITE $pubs{'gm-fungus'}; $pubs{'gm-fungus'} = "";
            }
            if ($soft_mask) {
                $perlCmdString .= " --soft_mask auto"
                    ; # version prior to 4.29, apparently also in version 4.33
                      #     $perlCmdString .= " --soft 1000"; # version 4.29
            }
            $perlCmdString .= " 1>$stdoutfile 2>$errorfile";
            print LOG "\# " . (localtime) . ": Executing gmes_petap.pl\n" 
                if ($v > 3);
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $perlCmdString\n"
                    . "Failed to execute: $perlCmdString\n"
                    . "The most common problem is an expired or not "
                    . "present file ~/.gm_key!\n");
            $cmdString = "cd $rootDir";
            print LOG "\# "
                . (localtime)
                . ": change to working directory $rootDir\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            chdir $rootDir
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not change to directory $rootDir.\n");
        } else {
            print LOG "\# " . (localtime) . ": skipping GeneMark-ET because "
                . "$genemarkDir/genemark.gtf is up to date.\n" if ($v > 3);
        }
    }
}

####################### GeneMark_EP ############################################
# * execute GeneMark-EP with protein intron hints for training
# * use output files of ProtHint ()
################################################################################

sub GeneMark_EP {
    print LOG "\# ". (localtime) . ": Running GeneMark-EP\n" if ($v > 2);
    print CITE $pubs{'gm-ep'}; $pubs{'gm-ep'} = "";
    print CITE $pubs{'gm-es'}; $pubs{'gm-es'} = "";
    print CITE $pubs{'diamond'}; $pubs{'diamond'} = "";
    print CITE $pubs{'spaln'}; $pubs{'spaln'} = "";
    print CITE $pubs{'spaln2'}; $pubs{'spaln2'} = "";
    if ( !$skipGeneMarkEP ) {
        if (!uptodate( [ $genome, $genemark_hintsfile ], 
            ["$genemarkDir/genemark.gtf"] ) || $overwrite ) {
            $cmdString = "cd $genemarkDir";
            print LOG "\# "
                . (localtime)
                . ": changing into GeneMark-EP directory $genemarkDir\n"
                if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            chdir $genemarkDir
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nCould not change into directory $genemarkDir.\n");
            $string        = "$GENEMARK_PATH/gmes_petap.pl";
            $errorfile     = "$errorfilesDir/GeneMark-EP.stderr";
            $stdoutfile    = "$otherfilesDir/GeneMark-EP.stdout";
            $perlCmdString = "";

            if ($nice) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString .= "perl $string --verbose ";
            if(defined($transmasked_fasta)){
                  $perlCmdString .= "--seq=$transmasked_fasta ";
            }else{
                  $perlCmdString .= "--seq $genome ";
            }
            if(defined($min_contig)){
                  $perlCmdString .= "--min_contig=$min_contig ";
            }
            $perlCmdString .= "--max_intergenic 50000 --ep_score 4,0.25 --EP "
                           .  "$otherfilesDir/prothint.gff --cores=$CPU --gc_donor $gc_prob";
            if(-e "$otherfilesDir/evidence.gff"){
                $perlCmdString .= " --evidence $otherfilesDir/evidence.gff ";
            }
            if ($fungus) {
                $perlCmdString .= " --fungus";
                print CITE $pubs{'gm-fungus'}; $pubs{'gm-fungus'} = "";
            }
            if ($soft_mask) {
                $perlCmdString .= " --soft_mask auto";
            }
            $perlCmdString .= " 1>$stdoutfile 2>$errorfile";
            print LOG "\# " . (localtime) . ": Running gmes_petap.pl\n" 
                if ($v > 3);
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $perlCmdString\n"
                    . "Failed to execute: $perlCmdString\n"
                    . "The most common problem is an expired or not "
                    . "present file ~/.gm_key!\n");
            $cmdString = "cd $rootDir";
            print LOG "\# "
                . (localtime)
                . ": change to working directory $rootDir\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            chdir $rootDir
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not change to directory $rootDir.\n");
        } else{
            print LOG "\# " . (localtime) . ": skipping GeneMark-EP because "
                . "$genemarkDir/genemark.gtf is up to date.\n" if ($v > 3);
        }
    } 
}

####################### GeneMark_ETP ###########################################
# * execute GeneMark-ET with protein and RNA-Seq intron hints for training
# * use introns represented in both sources as evidence for prediction
################################################################################

sub GeneMark_ETP {
    print LOG "\# " . (localtime) . ": Running GeneMark-ETP\n" if ($v > 2);
    print CITE $pubs{'gm-et'}; $pubs{'gm-et'} = "";
    print CITE $pubs{'gm-ep'}; $pubs{'gm-ep'} = "";
    print CITE $pubs{'gm-es'}; $pubs{'gm-es'} = "";
    print CITE $pubs{'diamond'}; $pubs{'diamond'} = "";
    print CITE $pubs{'spaln'}; $pubs{'spaln'} = "";
    print CITE $pubs{'spaln2'}; $pubs{'spaln2'} = "";
    if ( !$skipGeneMarkETP ) {
        if (!uptodate(
                [ $genome, $genemark_hintsfile ],
                ["$genemarkDir/genemark.gtf", "$genemarkDir/evidence.gtf"]
            )
            || $overwrite
            )
        {
            $cmdString = "cd $genemarkDir";
            print LOG "\# "
                . (localtime)
                . ": changing into GeneMark-ETP directory $genemarkDir\n" 
                if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            chdir $genemarkDir
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nCould not change into directory $genemarkDir.\n");
            $string        = "$GENEMARK_PATH/gmes_petap.pl";
            $errorfile     = "$errorfilesDir/GeneMark-ETP.stderr";
            $stdoutfile    = "$otherfilesDir/GeneMark-ETP.stdout";
            $perlCmdString = "";

            if ($nice) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString .= "perl $string --verbose ";
            if(defined($transmasked_fasta)){
                  $perlCmdString .= "--seq=$transmasked_fasta ";
            }else{
                  $perlCmdString .= "--seq $genome ";
            }
            if(defined($min_contig)){
                  $perlCmdString .= "--min_contig=$min_contig ";
            }
            $perlCmdString .= "--max_intergenic 50000 ";
            if(-e "$otherfilesDir/evidence.gff"){
                $perlCmdString .= "--evidence $otherfilesDir/evidence.gff ";
            }
            $perlCmdString .=  "--et_score 10 --ET $genemark_hintsfile "
                           .  "--cores=$CPU --gc_donor $gc_prob";
            if ($fungus) {
                $perlCmdString .= " --fungus";
                print CITE $pubs{'gm-fungus'}; $pubs{'gm-fungus'} = "";
            }
            if ($soft_mask) {
                $perlCmdString .= " --soft_mask auto";
            }
            $perlCmdString .= " 1>$stdoutfile 2>$errorfile";
            print LOG "\# " . (localtime) . ": Running gmes_petap.pl\n" 
                if ($v > 3);
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ . "\nFailed to execute: $perlCmdString\n"
                    . "Failed to execute: $perlCmdString\n"
                    . "The most common problem is an expired or not "
                    . "present file ~/.gm_key!\n");
            $cmdString = "cd $rootDir";
            print LOG "\# "
                . (localtime)
                . ": change to working directory $rootDir\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            chdir $rootDir
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not change to directory $rootDir.\n");
        } else{
            print LOG "\# " . (localtime) . ": skipping GeneMark-ETP because "
                . "$genemarkDir/genemark.gtf is up to date.\n" if ($v > 3);
        }
    }
}

####################### filter_genemark ########################################
# * GeneMark predictions contain (mostly) pure ab initio gene models
# * find those models that have support from extrinsic evidence, here
# * in case of single exon genes, select an appropriate proportion if no
#   evidence for single exon genes is available, randomly
################################################################################

sub filter_genemark {
    print LOG "\# " . (localtime) . ": Filtering output of GeneMark for "
        . "generating training genes for AUGUSTUS\n" if ($v > 2);

    if( not( $ESmode == 1 ) ) {
        if (!uptodate(
                [ "$genemarkDir/genemark.gtf", $hintsfile ],
                [   "$genemarkDir/genemark.c.gtf",
                    "$genemarkDir/genemark.f.good.gtf",
                    "$genemarkDir/genemark.average_gene_length.out"
                ] ) || $overwrite )
        {
            my $countSingleCDS = 0;
            if( not (-e "$genemarkDir/genemark.f.single_anchored.gtf") ){
                print LOG "\# "
                    . ( localtime )
                    . ": Checking whether hintsfile contains single exon CDSpart "
                    . "hints or start/stop hints\n" if ($v > 3);
                my %singleCDS;
                open ( HINTS, "<", $hintsfile ) or clean_abort(
                    "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                    "ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "Could not open file $hintsfile!\n" );
                my $hasStartStop = 0;
                while ( <HINTS> ) {
                    if( ($_ =~ m/\tstart\t/) or ($_ =~ m/\tstop\t/)){
                        $hasStartStop = 1;
                        last;
                    }
                    if( $_ =~ m/\tCDSpart\t.+grp=(\S+);/ ) {
                        if (not ( defined ($singleCDS{$1}) ) ) {
                            $singleCDS{$1} = $_;
                        }else{
                            $singleCDS{$1} = "0";
                        }
                    }
                }
                close ( HINTS ) or clean_abort(
                    "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                    "ERROR in file " . __FILE__ ." at line ". __LINE__
                    ."Could not close file $hintsfile!\n" );
                if($hasStartStop == 0){
                    # delete non single CDS genes from hash
                    # collapse multiplicity of singleCDS hints
                    my %multSingleCDS;
                    while (my ($k, $v) = each %singleCDS ) {
                        if ($v eq "0") {
                            delete $singleCDS{$k};
                        }else{
                            my @t = split(/\t/, $v);
                            if ( !defined( $multSingleCDS{$t[0]}{$t[6]}{$t[3]}{$t[4]} ) ) {
                                $multSingleCDS{$t[0]}{$t[6]}{$t[3]}{$t[4]} = 1;
                            }else{
                                $multSingleCDS{$t[0]}{$t[6]}{$t[3]}{$t[4]}++;
                            }
                        }
                    }
                    open ( SINGLECDS, ">", "$otherfilesDir/singlecds.hints" ) or
                        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                        "ERROR in file " . __FILE__ ." at line ". __LINE__
                        ."Could not open file $otherfilesDir/singlecds.hints!\n" );
                    while (my ($locus, $v1) = each %multSingleCDS ) {
                        while ( my ($strand, $v2) = each %{$v1} ) {
                            while ( my ($start, $v3 ) = each %{$v2} ) {
                                while ( my ($end, $v4) = each %{$v3} ) {
                                    print SINGLECDS "$locus\n.\nCDSpart\n$start\t$end\t.\t"
                                        . "$strand\t0\tsrc=P;mult=$v4;\n";
                                    $countSingleCDS++;
                                }
                            }
                        }
                    }
                    close ( SINGLECDS ) or clean_abort(
                        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                        "ERROR in file " . __FILE__ ." at line ". __LINE__
                        ."Could not close file $otherfilesDir/singlecds.hints!\n" );
                }
            }

            print LOG "\# "
                . (localtime)
                . ": filtering GeneMark genes by intron hints\n" if ($v > 3);
            $string = find(
                "filterGenemark.pl",    $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
            );
            $errorfile     = "$errorfilesDir/filterGenemark.stderr";
            $stdoutfile    = "$otherfilesDir/filterGenemark.stdout";
            $perlCmdString = "";
            if ($nice) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString .= "perl $string "
                           .  "--genemark=$genemarkDir/genemark.gtf "
                           .  "--hints=$hintsfile "
                           .  "--randomSeed=1 ";
            if ($filterOutShort) {
                $perlCmdString .= "--filterOutShort "
            }
            if ($countSingleCDS > 0 ) {
                $perlCmdString .= "--singleCDSfile=$otherfilesDir/singlecds.hints ";
            }
            $perlCmdString .= "1>$stdoutfile 2>$errorfile";
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $perlCmdString\n");


            my $minTrainGenes = 4000;
            print LOG "\# "
                . (localtime)
                . ": Ensuring at least $minTrainGenes genes in training file \n" if ($v > 3);
            $string = find(
                "ensure_n_training_genes.py",    $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
            );
            $errorfile     = "$errorfilesDir/ensure_min_n_training_genes.stderr";
            $stdoutfile    = "$otherfilesDir/ensure_min_n_training_genes.stdout";
            my $pythonCmdString = "";
            if ($nice) {
                $pythonCmdString .= "nice ";
            }
            $pythonCmdString .= "$PYTHON3_PATH/python3 $string "
                           .  "--goodGenes $genemarkDir/genemark.f.good.gtf "
                           .  "--badGenes $genemarkDir/genemark.f.bad.gtf "
                           .  "--N $minTrainGenes ";
            $pythonCmdString .= "1>$stdoutfile 2>$errorfile";
            print LOG "$pythonCmdString\n" if ($v > 3);
            system("$pythonCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $pythonCmdString\n");

        } else {
            print LOG "\# " . (localtime)
                . ": skip filtering genemark genes because file "
                . "$genemarkDir/genemark.f.good.gtf is up to date.\n" 
                if ($v > 3);
        }
    } else {
        # if no hints for filtering are provided (--esmode), filter by length:
        # keep those genes that are longer than 800 nt in CDS
        if (!uptodate([ "$genemarkDir/genemark.gtf"],
            [ "$genemarkDir/genemark.f.good.gtf"]) || $overwrite ) 
        {

            open( ESPRED, "<", "$genemarkDir/genemark.gtf" ) or 
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to open file "
                . "$genemarkDir/genemark.gtf\n");
            # compute CDS length of genes
            my %espred;
            while( <ESPRED> ) {
                chomp;
                my @l = split(/\t/);
                $l[8] =~ m/transcript_id \"([^"]+)\"/;
                my $trid = $1;
                push( @{$espred{$trid}{'line'}}, $_ );
                if( $_ =~ m/\tCDS\t/ ) {
                    if( !defined( $espred{$trid}{'len'}) ) {
                        $espred{$trid}{'len'} = $l[4] - $l[3] + 1;
                    } else {
                        $espred{$trid}{'len'} += $l[4] - $l[3] + 1;
                    }
                }
            }
            close( ESPRED ) or 
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to close file "
                . "$genemarkDir/genemark.gtf\n");

            open( ESPREDF, ">", "$genemarkDir/genemark.f.good.gtf" ) or 
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to open file "
                . "$genemarkDir/genemark.f.good.gtf\n");
            # print genes that are longer 800
            foreach(keys %espred) {
                if( $espred{$_}{'len'} >= 800 ) {
                    foreach( @{ $espred{$_}{'line'} } ) {
                        print ESPREDF $_."\n";
                    }
                }
            }
            close( ESPREDF ) or 
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to close file "
                . "$genemarkDir/genemark.f.good.gtf\n");

        } else {
            print LOG "\# " . (localtime)
                . ": Skip filtering genemark genes because file "
                . "$genemarkDir/genemark.f.good.gtf is up to date.\n" 
                if ($v > 3);
        }
    }


    if($lambda){
        if (!uptodate([ "$genemarkDir/genemark.f.good.gtf" ], 
            [ "$genemarkDir/genemark.d.gtf"] ) || $overwrite
        ){
            print LOG "\#"
                . (localtime)
                . ": downsampling good genemark genes according to poisson "
                . "distribution with Lambda $lambda:\n" if ($v > 3);
            $string = find(
            "downsample_traingenes.pl",    $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
            );
            $perlCmdString = "";
            if($nice){
                $perlCmdString .= "nice "
            }
            $perlCmdString .= "perl $string "
                           .  "--in_gtf=$genemarkDir/genemark.f.good.gtf "
                           .  "--out_gtf=$genemarkDir/genemark.d.gtf "
                           .  "--lambda=$lambda "
                           .  "1> $otherfilesDir/downsample_traingenes.log "
                           .  "2> $errorfilesDir/downsample_traingenes.err";
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $perlCmdString\n");
        } else {
            print LOG "\#" . (localtime)
                . ": skip downsampling because file "
                . "$genemarkDir/genemark.d.gtf is up to date.\n" if ($v > 3);
        }
    }
}


####################### new_species ############################################
# * create a new species parameter folder in AUGUSTUS_CONFIG_PATH/species
#   for AUGUSTUS
################################################################################

sub new_species {
    print LOG "\# " . (localtime) . ": Creating parameter template files for "
                    . "AUGUSTUS with new_species.pl\n" if ($v > 2);
    $augpath = "$AUGUSTUS_CONFIG_PATH/species/$species";
    if ((   !uptodate(
                [ $augpath . "/$species\_metapars.cfg" ],
                [   $augpath . "/$species\_parameters.cfg",
                    $augpath . "/$species\_exon_probs.pbl"
                ]
            )
            && !$useexisting
        )
        || !-d "$AUGUSTUS_CONFIG_PATH/species/$species"
        )
    {
        if ( -d "$AUGUSTUS_CONFIG_PATH/species" ) {
            if ( -w "$AUGUSTUS_CONFIG_PATH/species" ) {
                $string = find(
                    "new_species.pl",       $AUGUSTUS_BIN_PATH,
                    $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
                );
                $errorfile     = "$errorfilesDir/new_species.stderr";
                $perlCmdString = "";
                if ($nice) {
                    $perlCmdString .= "nice ";
                }
                $perlCmdString .= "perl $string --species=$species "
                               .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                               .  "1> /dev/null 2>$errorfile";
                print LOG "\# "
                    . (localtime)
                    . ": new_species.pl will create parameter files for "
                    . "species $species in "
                    . "$AUGUSTUS_CONFIG_PATH/species/$species\n" if ($v > 3);
                print LOG "$perlCmdString\n" if ($v > 3);
                system("$perlCmdString") == 0 or die(
                    "ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nFailed to create new species with new_species.pl, "
                    . "check write permissions in "
                    . "$AUGUSTUS_CONFIG_PATH/species directory! "
                    . "Command was $perlCmdString\n");
                if(not($ttable == 1)){
                    print LOG "\# "
                        . (localtime)
                        . ": setting translation_table to $ttable in file "
                        . "$AUGUSTUS_CONFIG_PATH/species/$species/$species\_parameters.cfg\n" if ($v > 3);
                    addParToConfig($AUGUSTUS_CONFIG_PATH
                                   . "/species/$species/$species\_parameters.cfg",
                                     "translation_table", "$ttable");
                    if($ttable =~ m/^(10|25|30|31)$/){
                        print LOG "\# " . (localtime)
                                  . ": Setting frequency of stop codon opalprob (TGA) to 0\n" if ($v > 3);
                        setParInConfig($AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                                       "/Constant/opalprob", 0);
                    }elsif($ttable =~ m/^(6|27|29)$/){
                        print LOG "\# " . (localtime)
                                  . ": Setting frequencies of stop codons ochreprob (TAA) and amberprob (TAG) to 0\n" if ($v > 3);
                        setParInConfig($AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                            "/Constant/ochreprob", 0);
                        setParInConfig($AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                            "/Constant/amberprob", 0);
                    }
                }

            } else {
                $prtStr = "\# "
                        . (localtime)
                        . ": ERROR: in file " . __FILE__ ." at line ". __LINE__
                        . "\nDirectory $AUGUSTUS_CONFIG_PATH/species is not "
                        . "writable! You must make the directory "
                        . "AUGUSTUS_CONFIG_PATH/species writable or specify "
                        . "another AUGUSTUS_CONFIG_PATH!\n";
                print LOG $prtStr;
                print STDERR $prtStr;
                exit(1);
            }
        } else {
            $prtStr = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__
                    ."\nDirectory $AUGUSTUS_CONFIG_PATH/species does not "
                    . "exist. Please check that AUGUSTUS_CONFIG_PATH is set, "
                    . "correctly!\n";
            print LOG $prtStr;
            print STDERR $prtStr;
            exit(1);
        }
    }
}

####################### training_augustus #######################################
# * train AUGUSTUS on the basis of generated training gene structures
# * in case of GeneMark training genes, flanking regions exclude parts that
#   were predicted as coding by GeneMark, even if the coding parts in potential
#   flanking regions did not qualify as evidence supported training genes
# * above is not the case for GenomeThreader training genes
# * if both GeneMark-ET and GenomeThreader genes are given, overlap on genomic
#   level is determined; GeneMark-ET genes are given preference (i.e. those
#   GenomeThreader genes will be deleted)
# * gtf is converted to genbank format for etraining
# * gene structures that produce etraining errors are deleted
# * CDS in training gene structures are BLASTed against themselves and redundant
#   gene structures are deleted
# * training genes are split into three sets:
#   a) for assessing accuracy of training (never used for training)
#   b) for etraining & optimize_augustus.pl
#   c) for testing during optimize_augustus.pl (also used for etraining, then)
# * UTR training is not included in this function
################################################################################

sub training_augustus {
    print LOG "\# " . (localtime) . ": training AUGUSTUS\n" if ($v > 2);
    if ( !$useexisting ) {
        my $gmGtf = "$genemarkDir/genemark.gtf";
        my $gthGtf = $gthTrainGeneFile;
        my $trainGenesGtf = "$otherfilesDir/traingenes.gtf";
        my $trainGb1 = "$otherfilesDir/train.gb";
        my $trainGb2 = "$otherfilesDir/train.f.gb";
        my $trainGb3 = "$otherfilesDir/train.ff.gb";
        my $trainGb4 = "$otherfilesDir/train.fff.gb";
        my $goodLstFile = "$otherfilesDir/good_genes.lst";
        my $t_b_t = 0; # to be tested gene set size, used to determine
                       # stop codon setting and to compute k for cores>8

        # set contents of trainGenesGtf file
        if ( not ($gth2traingenes) and not ($trainFromGth) ) {
            # create softlink from genemark.gtf to traingenes.gtf
            print LOG "\# "
                . (localtime)
                . ": creating softlink from $gmGtf to $trainGenesGtf.\n"
                if ($v > 3);
            $cmdString = "ln -s $gmGtf $trainGenesGtf";
            print LOG "$cmdString\n" if ($v > 3);
            system($cmdString) == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nfailed to execute: $cmdString!\n");
        } elsif ( $trainFromGth ) {
            # create softlink from gth.gtf to traingenes.gtf
             # make gth gb final
            print LOG "\#  "
                . (localtime)
                . ": creating softlink from $gthGtf to $trainGenesGtf.\n"
                if ($v > 3);
            $cmdString = "ln -s $gthGtf $trainGenesGtf";
            print LOG "$cmdString\n" if ($v > 3);
            system($cmdString) == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nfailed to execute: $cmdString!\n");
        } elsif ( $gth2traingenes and not ($trainFromGth) ) {
            # merge gth and gm gtf files
            combine_gm_and_gth_gtf ( $gmGtf,
                "$otherfilesDir/protein_alignment_$prg.gff3", $gthGtf,
                $trainGenesGtf);
        } else {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "unknown training gene generation scenario!\n";
            print STDERR $prtStr;
            clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                $prtStr);
        }

        # convert gtf to gb
        gtf2gb ($trainGenesGtf, $trainGb1);

        # count how many genes are in trainGb1
        my $nLociGb1 = count_genes_in_gb_file($trainGb1);
        if( $nLociGb1 == 0){
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Training gene file in genbank format $trainGb1 does not "
                . "contain any training genes. Possible known causes: (a) "
                . "no training genes were produced by GeneMark-ES/ET or " 
                . "GenomeThreader. In case of GeneMark-ES/ET, this may be due "
                . "to limited extrinsic evidence; in case of GenomeThreader, "
                . "this may be caused by usage of too distant protein "
                . "sequences; if you think this is the cause for your problems, "
                . "consider running BRAKER with different evidence or without "
                . "any evidence (--esmode) for training; "
                . "(b) complex FASTA headers in the genome file, "
                . "for example, a user reported that headers of the style "
                . "\'>NODE_1_length_397140_cov_125.503112 kraken:taxid|87257\'"
                . " caused our script for gtf to gb conversion to crash, while "
                . "a simple FASTA header such as \'>NODE_1\' worked fine; if "
                . "you think this is the cause for your problems, consider "
                . "simplifying the FASTA headers.\n";
            print STDERR $prtStr;
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                    $prtStr);
        }

        # filter "good" genes from train.gb: all gth genes that are left, plus
        # the genemark "good" genes
        if ( not ( $trainFromGth ) ) {
            if (not($lambda)){
                # get good genemark genes
                print LOG "\# "
                    . (localtime)
                    . ": concatenating good GeneMark training genes to "
                    . "$goodLstFile.\n" if ($v > 3);
                $cmdString = "cat $genemarkDir/genemark.f.good.gtf > $goodLstFile";
                print LOG "$cmdString\n" if ($v > 3);
                system($cmdString) == 0
                    or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                        $useexisting, "ERROR in file " . __FILE__ ." at line "
                        . __LINE__ ."\nfailed to execute: $cmdString!\n");
            }else{
                # get downsampled good genemark genes
                print LOG "\#  "
                    . (localtime)
                    . ": concatenating good and downsampled GeneMark training genes to "
                    . "$goodLstFile.\n" if ($v > 3);
                $cmdString = "cat $genemarkDir/genemark.d.gtf > $goodLstFile";
                print LOG "$cmdString\n" if ($v > 3);
                system($cmdString) == 0
                    or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                        $useexisting, "ERROR in file " . __FILE__ ." at line "
                        . __LINE__ ."\nfailed to execute: $cmdString!\n");
            }
        }

        if ( $gth2traingenes ) {
            print LOG "\#  "
                . (localtime)
                . ": concatenating good GenomeThreader training genes to "
                . "$goodLstFile.\n" if ($v > 3);
            # get all remaining gth genes
            open (GOODLST, ">>", $goodLstFile) or clean_abort(
                "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                "ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nCould not open file $goodLstFile!\n" );
            open ( GTHGOOD, "<", $trainGenesGtf ) or clean_abort(
                "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                "ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nCould not open file $trainGenesGtf!\n" );
            while ( <GTHGOOD> ) {
                if ( $_ =~ m/\tgth\t/ ) {
                    print GOODLST $_;
                }
            }
           close ( GTHGOOD ) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $trainGenesGtf!\n" );
           close (GOODLST) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $goodLstFile!\n" );
        }

        # check whether goodLstFile has any content
        open (GOODLST, "<", $goodLstFile) or clean_abort(
             "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
             "ERROR in file " . __FILE__ ." at line ". __LINE__
             . "\nCould not open file $goodLstFile!\n" );
        while(<GOODLST>){};
        my $nGoodGenes = $.;
        close (GOODLST) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $goodLstFile!\n" );
        if($nGoodGenes < 1){
            $prtStr = "\# "
                . (localtime)
                . " ERROR: file $goodLstFile contains no good training genes."
                . " This means that with RNA-Seq data, there was insufficient"
                . " coverage of introns; or with protein data, there was "
                . "insufficient support from protein alignments/GaTech protein"
                . " mapping pipeline hints; or without any evidence, there "
                . " were only very short genes. In most cases, you will see "
                . " this happening if BRAKER was executed with some kind of "
                . " extrinsic evidence (either/or RNA-Seq/protein). You can then "
                . " try to re-run BRAKER without any evidence for training "
                . " and later use the such trained AUGUSTUS parameters for a "
                . " BRAKER run without any training and the available evidence."
                . " Accuracy of training without any evidence is lower than with "
                . " good evidence.\n";
            print LOG $prtStr;
            print STDERR $prtStr;
            clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $   useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nNo genes for training in file $goodLstFile!\n");
        }

        # filter good genes from trainGb1 into trainGb2
        $string = find(
                "filterGenesIn_mRNAname.pl",       $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
            );
        $errorfile     = "$errorfilesDir/filterGenesIn_mRNAname.stderr";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString
            .= "perl $string $goodLstFile $trainGb1 > $trainGb2 2>$errorfile";
        print LOG "\# "
            . (localtime)
            . ": Filtering train.gb for \"good\" mRNAs:\n" if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $perlCmdString\n");

        # count how many genes are in trainGb2
        my $nLociGb2 = count_genes_in_gb_file($trainGb2);
        if( $nLociGb2 == 0){
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Training gene file in genbank format $trainGb2 does not "
                . "contain any training genes. Possible known cause: "
                . "no training genes with sufficient extrinsic evidence support "
                . "or of sufficient length were produced by GeneMark-ES/ET. "
                .  "If you think this is the cause for your problems, "
                . "consider running BRAKER with different evidence or without "
                . "any evidence (--esmode) for training.\n";
            print STDERR $prtStr;
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                    $prtStr);
        }

        # filter out genes that lead to etraining errors
        $augpath    = "$AUGUSTUS_BIN_PATH/etraining";
        $errorfile  = "$errorfilesDir/gbFilterEtraining.stderr";
        $stdoutfile = "$otherfilesDir/gbFilterEtraining.stdout";
        $cmdString  = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        # species is irrelevant!
        $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $trainGb2 1> $stdoutfile 2>$errorfile";
        print LOG "\# "
            . (localtime)
            . ": Running etraining to catch gene structure inconsistencies:\n"
            if ($v > 3);
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $cmdString\n");
        open( ERRS, "<", $errorfile )
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ . "\nCould not open file $errorfile!\n");
        open( BADS, ">", "$otherfilesDir/etrain.bad.lst" )
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__
                ."\nCould not open file $otherfilesDir/etrain.bad.lst!\n");
        while (<ERRS>) {
            if (m/n sequence (\S+):.*/) {
                print BADS "$1\n";
            }
        }
        close(BADS)
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__
                ."\nCould not close file $otherfilesDir/etrain.bad.lst!\n");
        close(ERRS) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $errorfile!\n");
        $string = find(
            "filterGenes.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $errorfile     = "$errorfilesDir/etrainFilterGenes.stderr";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString
            .= "perl $string $otherfilesDir/etrain.bad.lst $trainGb2 1> $trainGb3 2>$errorfile";
        print LOG "\# "
            . (localtime)
            . ": Filtering $trainGb2 file to remove inconsistent gene structures...\n" if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $perlCmdString\n");

        # count how many genes are in trainGb3
        my $nLociGb3 = count_genes_in_gb_file($trainGb3);
        if( $nLociGb3 == 0){
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Training gene file in genbank format $trainGb3 does not "
                . "contain any training genes. At this stage, we performed a "
                . "filtering step that discarded all genes that lead to etraining "
                . "errors. If you lost all training genes, now, that means you "
                . "probably have an extremely fragmented assembly where all training "
                . "genes are incomplete, or similar.\n";
            print STDERR $prtStr;
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                    $prtStr);
        }

        # reduce gene set size if >8000. We introduce this step because in esmode,
        # sometimes, there is a such a huge number of putative training genes
        # that optimize_augustus.pl runs into a memory access problem 
        # (not understood why exactly, yet, but it is a parallelization issue)
        # also, BLASTing a very high number of genes takes way too long
        # might want to reconsider the threshold (8000?)
        if($nLociGb3 > $maxTrainGenes){
            print LOG "\# "
                . (localtime)
                . ": Reducing number of training genes by random selection to $maxTrainGenes.\n";
            $string = find(
                "randomSplit.pl",       $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
            );
            $errorfile = "$errorfilesDir/randomSplit_8000.stderr";
            $perlCmdString = "";
            if ($nice) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString .= "perl $string $trainGb3 $maxTrainGenes 2>$errorfile";
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $perlCmdString\n");
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "mv $trainGb3.test $trainGb3";
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $cmdString\n");
        }

        # find those training genes in gtf that are still in gb
        open (TRAINGB3, "<", $trainGb3) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $trainGb3!\n" );
        my %txInGb3;
        my $txLocus;;
        while( <TRAINGB3> ) {
            if ( $_ =~ m/LOCUS\s+(\S+)\s/ ) {
                $txLocus = $1;
            }elsif ( $_ =~ m/\/gene=\"(\S+)\"/ ) {
                $txInGb3{$1} = $txLocus;
            }
        }
        close (TRAINGB3) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $trainGb3!\n" );

        # filter in those genes that are good
        open (GTF, "<", $trainGenesGtf) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $trainGenesGtf!\n");
        open (GOODGTF, ">", "$otherfilesDir/traingenes.good.gtf") or
            clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__
                . "\nCould not open file "
                . "$otherfilesDir/traingenes.good.gtf!\n");
        while(<GTF>){
            if($_ =~ m/transcript_id \"(\S+)\"/){
                if(defined($txInGb3{$1})){
                    print GOODGTF $_;
                }
            }
        }
        close(GOODGTF) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__
            ."\nCould not close file $otherfilesDir/traingenes.good.gtf!\n");
        close(GTF) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $trainGenesGtf!\n");

        # convert those training genes to protein fasta file
        gtf2fasta ($genome, "$otherfilesDir/traingenes.good.gtf",
            "$otherfilesDir/traingenes.good.fa", $ttable);

        # blast or diamond good training genes to exclude redundant sequences
        $string = find(
            "aa2nonred.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $errorfile     = "$errorfilesDir/aa2nonred.stderr";
        $stdoutfile    = "$otherfilesDir/aa2nonred.stdout";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        if(defined($DIAMOND_PATH) and not(defined($blast_path))){
            $perlCmdString .= "perl $string $otherfilesDir/traingenes.good.fa "
                           .  "$otherfilesDir/traingenes.good.nr.fa "
                           .  "--DIAMOND_PATH=$DIAMOND_PATH --cores=$CPU "
                           .  "--diamond 1> $stdoutfile 2>$errorfile";
            print CITE $pubs{'diamond'}; $pubs{'diamond'} = "";
        }else{
            $perlCmdString .= "perl $string $otherfilesDir/traingenes.good.fa "
                           .  "$otherfilesDir/traingenes.good.nr.fa "
                           .  "--BLAST_PATH=$BLAST_PATH --cores=$CPU 1> "
                           .  "$stdoutfile 2>$errorfile";
            print CITE $pubs{'blast1'}; $pubs{'blast1'} = "";
            print CITE $pubs{'blast2'}; $pubs{'blast2'} = "";
        }
        print LOG "\# "
            . (localtime)
            . ": BLAST or DIAMOND training gene structures against themselves:\n" if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $perlCmdString\n");

        # parse output of blast
        my %nonRed;
        open (BLASTOUT, "<", "$otherfilesDir/traingenes.good.nr.fa") or
            clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__
            ."\nCould not open file $otherfilesDir/traingenes.good.nr.fa!\n");
        while ( <BLASTOUT> ) {
            chomp;
            if($_ =~ m/^\>(\S+)/){
                $nonRed{$1} = 1;
            }
        }
        close (BLASTOUT) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            ."\nCould not close file $otherfilesDir/traingenes.good.nr.fa!\n" );

        open ( NONREDLOCI, ">", "$otherfilesDir/nonred.loci.lst") or
            clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__
            ."\nCould not open file $otherfilesDir/nonred.loci.lst!\n");
        foreach ( keys %nonRed ) {
            print NONREDLOCI $txInGb3{$_}."\n";
        }
        close (NONREDLOCI) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $otherfilesDir/nonred.loci.lst!\n");

        # filter trainGb3 file for nonredundant loci
        $string = find(
            "filterGenesIn.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $errorfile     = "$errorfilesDir/filterGenesIn.stderr";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString
            .= "perl $string $otherfilesDir/nonred.loci.lst $trainGb3 1> $trainGb4 2>$errorfile";
        print LOG "\# "
            . (localtime)
            . ": Filtering nonredundant loci into $trainGb4:\n" if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $perlCmdString\n");

        # count how many genes are in trainGb4
        my $gb_good_size = count_genes_in_gb_file($trainGb4);
        if( $gb_good_size == 0){
            $prtStr = "\# "
                    . (localtime)
                    . " ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "Number of reliable training genes is 0, so the parameters cannot "
                    . "be optimized. Recommended are at least 600 genes\n"
                    . "You may try --esmode (running BRAKER without evidence, if you haven't done) "
                    . "this already), in order "
                    . "to obtain species specific parameters for your species, and later "
                    . "re-run BRAKER with evidence with --skipAllTraining, using the previously "
                    . "trained parameters. However, prediction accuracy may be low.\n";
                print LOG $prtStr;
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, $prtStr);
        }

        # making trainGb4 the trainGb file
        $cmdString = "mv $trainGb4 $trainGb1";
        print LOG "\# "
            . (localtime)
            . ": Moving $trainGb4 to $trainGb1:\n" if ($v > 3);
        print LOG "$cmdString\n" if ($v > 3);
        system ("$cmdString") == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            ."\nFailed to execute: $cmdString!\n");

        # split into training and test set
        if (!uptodate(
                ["$otherfilesDir/train.gb"],
                [   "$otherfilesDir/train.gb.test",
                    "$otherfilesDir/train.gb.train"
                ]
            )
            || $overwrite
            )
        {
            print LOG "\# "
                . (localtime)
                . ": Splitting genbank file into train and test file\n" if ($v > 3);
            $string = find(
                "randomSplit.pl",       $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
            );
            $errorfile = "$errorfilesDir/randomSplit.stderr";
            if ( $gb_good_size < 600 ) {
                $prtStr = "#*********\n"
                        . "# WARNING: Number of reliable training genes is low ($gb_good_size). "
                        . "Recommended are at least 600 genes\n"
                        . "#*********\n";
                print LOG $prtStr if ($v > 0);
                print STDOUT $prtStr if ($v > 0);
                $testsize1 = floor($gb_good_size/3);
                $testsize2 = floor($gb_good_size/3);
                if( $testsize1 == 0 or $testsize2 == 0 or ($gb_good_size - ($testsize1 + $testsize2)) == 0 ){
                    $prtStr = "\# "
                            . (localtime)
                            . " ERROR: in file " . __FILE__ ." at line "
                            . __LINE__ ."\nUnable to create three genbank"
                            . "files for optimizing AUGUSTUS (number of LOCI "
                            . "too low)! \n"
                            . "\$testsize1 is $testsize1, \$testsize2 is "
                            . "$testsize2, additional genes are "
                            . ($gb_good_size - ($testsize1 + $testsize2))
                            . "\nThe provided input data is not "
                            . "sufficient for running braker.pl!\n";
                    print LOG $prtStr;
                    clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                        $useexisting, $prtStr);
                }
            }elsif ( $gb_good_size >= 600 && $gb_good_size <= 1000 ) {
                $testsize1 = 200;
                $testsize2 = 200;
            }else{
                $testsize1 = 300;
                $testsize2 = 300;
            }
            $perlCmdString = "";
            if ($nice) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString
                .= "perl $string $trainGb1 $testsize1 2>$errorfile";
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $perlCmdString\n");
            print LOG "\# "
                        . (localtime)
                        . ": $otherfilesDir/train.gb.test will be used for "
                        . "measuring AUGUSTUS accuracy after training\n" if ($v > 3);
            if($v > 3) {
                count_genes_in_gb_file("$otherfilesDir/train.gb.test");
                count_genes_in_gb_file("$otherfilesDir/train.gb.train");
            }
            $perlCmdString = "";
            if ($nice) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString .= "perl $string $otherfilesDir/train.gb.train $testsize2 2>$errorfile";
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $perlCmdString\n");

            if($v > 3) {
                count_genes_in_gb_file("$otherfilesDir/train.gb.train.train");
                count_genes_in_gb_file("$otherfilesDir/train.gb.train.test");
            }

            print LOG "\# "
                . (localtime)
                . ": $otherfilesDir/train.gb.train.test will be used or "
                . "measuring AUGUSTUS accuracy during training with "
                . "optimize_augustus.pl\n"
                . " $otherfilesDir/train.gb.train.train will be used for "
                . "running etraining in optimize_augustus.pl (together with "
                . "train.gb.train.test)\n"
                . " $otherfilesDir/train.gb.train will be used for running "
                . "etraining (outside of optimize_augustus.pl)\n" if ($v > 3);
        }

        # train AUGUSTUS for the first time
        if (!uptodate(
                [   "$otherfilesDir/train.gb.train",
                    "$otherfilesDir/train.gb.test"
                ],
                ["$otherfilesDir/firstetraining.stdout"]
            )
            )
        {
            # set "stopCodonExcludedFromCDS" to true
            print LOG "\# "
                . (localtime)
                . ": Setting value of \"stopCodonExcludedFromCDS\" in "
                . "$AUGUSTUS_CONFIG_PATH/species/$species/$species\_parameters.cfg "
                . "to \"true\"\n" if ($v > 3);
            setParInConfig(
                $AUGUSTUS_CONFIG_PATH
                    . "/species/$species/$species\_parameters.cfg",
                "stopCodonExcludedFromCDS", "true"
            );

            # first try with etraining
            $augpath    = "$AUGUSTUS_BIN_PATH/etraining";
            $errorfile  = "$errorfilesDir/firstetraining.stderr";
            $stdoutfile = "$otherfilesDir/firstetraining.stdout";
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/train.gb.train 1>$stdoutfile 2>$errorfile";
            print LOG "\# " . (localtime) . ": first etraining\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute $cmdString\n");

            # set "stopCodonExcludedFromCDS" to false and run etraining again if necessary
            $t_b_t = $gb_good_size - $testsize1;
            my $err_stopCodonExcludedFromCDS;
            if ($nice) {
                print LOG "nice grep -c \"exon doesn't end in stop codon\" "
                    . "$errorfile\n" if ($v > 3);
                $err_stopCodonExcludedFromCDS = `nice grep -c "exon doesn't end in stop codon" $errorfile` if ($v > 3);
            }
            else {
                print LOG "grep -c \"exon doesn't end in stop codon\" "
                    . "$errorfile\n" if ($v > 3);
                $err_stopCodonExcludedFromCDS = `grep -c "exon doesn't end in stop codon" $errorfile` if ($v > 3);
            }
            my $err_rate = $err_stopCodonExcludedFromCDS
                / $t_b_t;
            print LOG "\# "
                . (localtime)
                . ": Error rate of missing stop codon is $err_rate\n"
                 if ($v > 3);
            if ( $err_rate >= 0.5 ) {
                print LOG "\# "
                    . (localtime)
                    . ": The appropriate value for \"stopCodonExcludedFromCDS\" "
                    . "seems to be \"false\".\n" if ($v > 3);
                print LOG "\# "
                    . (localtime)
                    . ": Setting value of \"stopCodonExcludedFromCDS\" in "
                    . "$AUGUSTUS_CONFIG_PATH/species/$species/$species\_parameters.cfg "
                    . "to \"false\"\n" if ($v > 3);
                setParInConfig(
                    $AUGUSTUS_CONFIG_PATH
                        . "/species/$species/$species\_parameters.cfg",
                    "stopCodonExcludedFromCDS",
                    "false"
                );
                print LOG "\# "
                    . (localtime)
                    . ": Running etraining again\n" if ($v > 3);
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0
                    or die("ERROR in file " . __FILE__ ." at line "
                        . __LINE__ ."\nFailed to execute $cmdString\n");
            }

            # adjust the stop-codon frequency in species_parameters.cfg
            # according to train.out
            print LOG "\# "
                . (localtime)
                . ": Adjusting stop-codon frequencies in "
                . "species_parameters.cfg according to $stdoutfile\n"
                if ($v > 3);
            my $freqOfTag;
            my $freqOfTaa;
            my $freqOfTga;
            open( TRAIN, "$stdoutfile" )
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nCan not open file $stdoutfile!\n");
            while (<TRAIN>) {
                if (/tag:\s*.*\((.*)\)/) {
                    $freqOfTag = $1;
                }
                elsif (/taa:\s*.*\((.*)\)/) {
                    $freqOfTaa = $1;
                }
                elsif (/tga:\s*.*\((.*)\)/) {
                    $freqOfTga = $1;
                }
            }
            close(TRAIN) or die("ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nCould not close gff file $stdoutfile!\n");
            if($ttable == 1){
                print LOG "\# "
                    . (localtime)
                    . ": Setting frequency of stop codons to tag=$freqOfTag, "
                    . "taa=$freqOfTaa, tga=$freqOfTga.\n" if ($v > 3);
                setParInConfig(
                    $AUGUSTUS_CONFIG_PATH
                        . "/species/$species/$species\_parameters.cfg",
                    "/Constant/amberprob", $freqOfTag
                );
                setParInConfig(
                    $AUGUSTUS_CONFIG_PATH
                        . "/species/$species/$species\_parameters.cfg",
                    "/Constant/ochreprob", $freqOfTaa
                );
                setParInConfig(
                    $AUGUSTUS_CONFIG_PATH
                        . "/species/$species/$species\_parameters.cfg",
                    "/Constant/opalprob", $freqOfTga
                );
            }elsif($ttable =~ m/^(10|25|30|31)$/){
                print LOG "\# " . (localtime)
                          . ": Setting frequency of stop codon opalprob (TGA) to 0\n" if ($v > 3);
                setParInConfig($AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                               "/Constant/opalprob", 0);
                if(not($freqOfTga == 0)){ # distribute false probablity to the other two codons
                    $freqOfTaa = $freqOfTaa + $freqOfTga/2;
                    $freqOfTag = $freqOfTag + $freqOfTga/2;
                }
                setParInConfig(
                    $AUGUSTUS_CONFIG_PATH
                        . "/species/$species/$species\_parameters.cfg",
                    "/Constant/amberprob", $freqOfTag
                );
                setParInConfig(
                    $AUGUSTUS_CONFIG_PATH
                        . "/species/$species/$species\_parameters.cfg",
                    "/Constant/ochreprob", $freqOfTaa
                );
            }elsif($ttable =~ m/^(6|27|29)$/){
                        print LOG "\# " . (localtime)
                                  . ": Setting frequencies of stop codons ochreprob (TAA) and " 
                                  . "amberprob (TAG) to 0 and opalprob (TGA) to 1\n" if ($v > 3);
                        setParInConfig($AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                            "/Constant/ochreprob", 0);
                        setParInConfig($AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                            "/Constant/amberprob", 0);
                        setParInConfig( $AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                            "/Constant/opalprob", 1);
            }
        }

        # first test
        if (!uptodate(
                [   "$otherfilesDir/train.gb.test"],
                ["$otherfilesDir/firsttest.stdout"]
            )
            || $overwrite
            )
        {
            $augpath    = "$AUGUSTUS_BIN_PATH/augustus";
            $errorfile  = "$errorfilesDir/firsttest.stderr";
            $stdoutfile = "$otherfilesDir/firsttest.stdout";
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/train.gb.test 1>$stdoutfile 2>$errorfile";
            print LOG "\# "
                . (localtime)
                . ": First AUGUSTUS accuracy test\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nFailed to execute: $cmdString!\n");
            $target_1 = accuracy_calculator($stdoutfile);
            print LOG "\# "
                . (localtime)
                . ": The accuracy after initial training "
                . "(no optimize_augustus.pl, no CRF) is $target_1\n"
                if ($v > 3);
        }

        # optimize parameters
        if ( !$skipoptimize ) {
            if (!uptodate(
                    [   "$otherfilesDir/train.gb.train.train",
                        "$otherfilesDir/train.gb.train.test"
                    ],
                    [   $AUGUSTUS_CONFIG_PATH
                            . "/species/$species/$species\_exon_probs.pbl",
                        $AUGUSTUS_CONFIG_PATH
                            . "/species/$species/$species\_parameters.cfg",
                        $AUGUSTUS_CONFIG_PATH
                            . "/species/$species/$species\_weightmatrix.txt"
                    ]
                )
                )
            {
                $string = find(
                    "optimize_augustus.pl", $AUGUSTUS_BIN_PATH,
                    $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
                );
                $errorfile  = "$errorfilesDir/optimize_augustus.stderr";
                $stdoutfile = "$otherfilesDir/optimize_augustus.stdout";
                my $k_fold = 8;
                if($CPU > 1){
                    for(my $i=1; $i<=$CPU; $i++){
                        if ($t_b_t/$i > 200){
                            $k_fold = $i;
                        }
                    }   
                }
                if($k_fold < 8) {
                    $k_fold = 8;
                }
                $perlCmdString = "";
                if ($nice) {
                    $perlCmdString .= "nice ";
                }
                $perlCmdString .= "perl $string ";
                if ($nice) {
                    $perlCmdString .= "--nice "
                }
                $perlCmdString  .= "--aug_exec_dir=$AUGUSTUS_BIN_PATH --rounds=$rounds "
                                 . "--species=$species "
                                 . "--kfold=$k_fold "
                                 . "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                                 . "--onlytrain=$otherfilesDir/train.gb.train.train ";
                if($CPU > 1) {
                    $perlCmdString .= "--cpus=$k_fold ";
                }
                $perlCmdString  .= "$otherfilesDir/train.gb.train.test "
                                . "1>$stdoutfile 2>$errorfile";
                print LOG "\# "
                    . (localtime)
                    . ": optimizing AUGUSTUS parameters\n" if ($v > 3);
                print LOG "$perlCmdString\n" if ($v > 3);
                system("$perlCmdString") == 0
                    or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nFailed to execute: $perlCmdString!\n");
                print LOG "\# "
                    . (localtime)
                    . ":  parameter optimization finished.\n" if ($v > 3);
            }
        }

        # train AUGUSTUS for the second time
        if (!uptodate(
                ["$otherfilesDir/train.gb.train"],
                ["$otherfilesDir/secondetraining.stdout"]
            )
            )
        {
            $augpath    = "$AUGUSTUS_BIN_PATH/etraining";
            $errorfile  = "$errorfilesDir/secondetraining.stderr";
            $stdoutfile = "$otherfilesDir/secondetraining.stdout";
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "$augpath --species=$species "
                       .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                       .  "$otherfilesDir/train.gb.train 1>$stdoutfile "
                       .  "2>$errorfile";
            print LOG "\# " . (localtime) . ": Second etraining\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nFailed to execute: $cmdString!\n");
        }

        # second test
        if (!uptodate(
                [   "$otherfilesDir/train.gb.test"],
                ["$otherfilesDir/secondtest.out"]
            )
            || $overwrite
            )
        {
            $augpath    = "$AUGUSTUS_BIN_PATH/augustus";
            $errorfile  = "$errorfilesDir/secondtest.stderr";
            $stdoutfile = "$otherfilesDir/secondtest.stdout";
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString
                .= "$augpath --species=$species "
                .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                .  "$otherfilesDir/train.gb.test >$stdoutfile 2>$errorfile";
            print LOG "\# "
                . (localtime)
                . ": Second AUGUSTUS accuracy test\n" if ($v > 3);
            print LOG "$cmdString\n";
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nFailed to execute: $cmdString\n");
            $target_2 = accuracy_calculator($stdoutfile);
            print LOG "\# " . (localtime) . ": The accuracy after training "
                . "(after optimize_augustus.pl, no CRF) is $target_2\n"
                if ($v > 3);
        }

        # optional CRF training
        if ($crf) {
            if (!uptodate(
                    ["$otherfilesDir/train.gb.train"],
                    ["$otherfilesDir/crftraining.stdout"]
                )
                || $overwrite
                )
            {
                $augpath = "$AUGUSTUS_BIN_PATH/etraining";
            }
            $errorfile  = "$errorfilesDir/crftraining.stderr";
            $stdoutfile = "$otherfilesDir/crftraining.stdout";
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "$augpath --species=$species --CRF=1 "
                       .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                       .  "$otherfilesDir/train.gb.train 1>$stdoutfile "
                       .  "2>$errorfile";
            print LOG "\# "
                . (localtime)
                . ": Third etraining - now with CRF\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nfailed to execute: $cmdString\n");
            print LOG "\# "
                . (localtime)
                . ": etraining with CRF finished.\n" if ($v > 3);

            # third test
            if (!uptodate(
                    ["$otherfilesDir/train.gb.test"],
                    ["$otherfilesDir/thirdtest.out"]
                )
                || $overwrite
                )
            {
                $augpath    = "$AUGUSTUS_BIN_PATH/augustus";
                $errorfile  = "$errorfilesDir/thirdtest.stderr";
                $stdoutfile = "$otherfilesDir/thirdtest.stdout";
                $cmdString = "";
                if ($nice) {
                    $cmdString .= "nice ";
                }
                $cmdString .= "$augpath --species=$species "
                           .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                           .  "$otherfilesDir/train.gb.test >$stdoutfile "
                           .  "2>$errorfile";
                print LOG "\# "
                    . (localtime)
                    . ": Third AUGUSTUS accuracy test\n" if ($v > 3);
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0
                    or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nFailed to execute: $cmdString\n");
                $target_3 = accuracy_calculator($stdoutfile);
                print LOG "\# ". (localtime) . ": The accuracy after CRF "
                    . "training is $target_3\n" if ($v > 3);
            }

            # decide on whether to keep CRF parameters
            if ( $target_2 > $target_3 && !$keepCrf ) {
                print LOG "\# "
                    . (localtime)
                    . ": CRF performance is worse than HMM performance, "
                    . "reverting to usage of HMM paramters.\n" if ($v > 3);
            }
            else {
                print LOG "\# "
                    . (localtime)
                    . ": CRF performance is better than HMM performance, "
                    . "keeping CRF paramters.\n" if ($v > 3);
            }

            # cp config files
            print LOG "\# "
                . (localtime)
                . ": Copying parameter files to $species*.CRF\n" if ($v > 3);
            for (
                (   "$species" . "_exon_probs.pbl",
                    "$species" . "_igenic_probs.pbl",
                    "$species" . "_intron_probs.pbl"
                )
                )
            {
                $cmdString = "cp $AUGUSTUS_CONFIG_PATH/species/$species/$_ "
                           . "$AUGUSTUS_CONFIG_PATH/species/$species/$_" . ".CRF";
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0
                    or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nfailed to execute: $cmdString\n");
            }

            # if the accuracy doesn't improve with CRF, overwrite the config
            # files with the HMM parameters from last etraining
            if ( ( $target_2 > $target_3 ) && !$keepCrf ) {
                print LOG "\# "
                    . (localtime)
                    . ": overwriting parameter files resulting from CRF "
                    . "training with original HMM files\n" if ($v > 3);
                for (
                    (   "$species" . "_exon_probs.pbl",
                        "$species" . "_igenic_probs.pbl",
                        "$species" . "_intron_probs.pbl"
                    )
                    )
                {
                    $cmdString
                        = "rm $AUGUSTUS_CONFIG_PATH/species/$species/$_";
                    print LOG "$cmdString\n" if ($v > 3);
                    system("$cmdString") == 0
                        or die("ERROR in file " . __FILE__ ." at line "
                            . __LINE__ ."\nFailed to execute: $cmdString\n");
                    print LOG "$cmdString\n" if ($v > 3);
                    $cmdString
                        = "cp $AUGUSTUS_CONFIG_PATH/species/$species/$_"
                        . ".HMM $AUGUSTUS_CONFIG_PATH/species/$species/$_";
                    system("$cmdString") == 0
                        or die("ERROR in file " . __FILE__ ." at line "
                            . __LINE__ ."\nFailed to execute: $cmdString\n");
                }
            }
        }
    }

    # copy species files to working directory
    if ( !-d "$parameterDir/$species" ) {
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString
            .= "cp -r $AUGUSTUS_CONFIG_PATH/species/$species $parameterDir";
        print LOG "\# "
            . (localtime)
            . ": Copying optimized parameters to working directory"
            . " $parameterDir\n" if ($v > 3);
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            ." at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
    }
}

####################### fix_ifs_genes ##########################################
# * AUGUSTUS sometimes predicts genes with in frame stop codons (IFSs)
#   if the stop codon is spliced/contains an intron
# * this function re-predicts in regions with IFSs genes using AUGUSTUS mea
#   (instead of Viterbi)
# * arguments:
#   $label -> unique identifier for the AUGUSTUS run that is postprocessed
#   $gtf_in -> gtf output file of AUGUSTUS run
#   $bad_lst -> output file of getAnnoFastaFromJoingenes.py
#   $utr_here -> on/off
#   $spec -> augustus species name 
#   $aug_c_p -> AUGUSTUS_CONFIG_PATH
#   $aug_b_p -> AUGUSTUS_BIN_PATH
#   $aug_s_p -> AUGUSTUS_SCRIPTS_PATH
#   Optional:
#   $h_file -> hints file for this AUGUSTUS run
#   $cfg_file -> extrinsic config file for hints
################################################################################

sub fix_ifs_genes{
    my ($label, $gtf_in, $bad_lst, $utr_here, $spec, 
         $aug_c_p, $aug_b_p, $aug_s_p, $h_file, $cfg_file) = @_;
    #print("Overview of fix_ifs_genes arguments:\n");
    #foreach(@_){
    #    print $_."\n";
    #}
    my $fix_ifs_out_stem = $label."_fix_ifs_";
    my $print_utr_here = "off";
    if($utr_here eq "on"){
        $print_utr_here = "on";
    }
    print LOG "\# " . (localtime) . ": fixing AUGUSTUS genes with in frame "
            . "stop codons...\n" if ($v > 2);
    $string = find( "fix_in_frame_stop_codon_genes.py", $aug_b_p, 
        $aug_s_p, $aug_c_p );
    my $cmdStr = $PYTHON3_PATH . "/python3 " . $string ." -g " . $genome 
               . " -t $gtf_in -b $bad_lst -o $fix_ifs_out_stem -s $spec ";
    if($soft_mask){
        $cmdStr .= "-m on ";
    }else{
        $cmdStr .= "-m off ";
    }
    $cmdStr .= "--UTR $utr_here --print_utr $print_utr_here -a $aug_c_p "
             . "-C $CDBTOOLS_PATH -A $aug_b_p -S $aug_s_p ";
    if ( defined($h_file) and defined($cfg_file) ) {
        $cmdStr .= "-H $h_file -e $cfg_file ";
    }
    $cmdStr .= " > $otherfilesDir/fix_in_frame_stop_codon_genes_".$label.".log "
            ."2> $errorfilesDir/fix_in_frame_stop_codon_genes_".$label.".err";
    print LOG $cmdStr . "\n"  if ($v > 3);
    system("$cmdStr") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdStr\n");
    print LOG "\# " . (localtime) . ": Moving gene prediction file "
                    . "without in frame stop codons to location of "
                    . "original file (overwriting it)...\n" if ($v > 2);
    $cmdStr = "mv $otherfilesDir/$label"."_fix_ifs_".".gtf $gtf_in";
    print LOG $cmdStr."\n" if ($v > 3);
    system("$cmdStr") == 0
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to execute: $cmdStr\n");
    $cmdStr = "rm $otherfilesDir/bad_genes.lst\n";
    print LOG "\# " . (localtime) . ": Deleting file with genes with in frame "
                    . "stop codons...\n";
    print LOG $cmdStr;
    unlink("$otherfilesDir/bad_genes.lst");
}


####################### count_genes_in_gb_file #################################
# * return count of LOCUS tags in genbank file
################################################################################

sub count_genes_in_gb_file {
    my $gb_file = shift;
    open (GBFILE, "<", $gb_file) or
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "\# " . (localtime)
        . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
        . "Could not open file $gb_file!\n");
    my $nLociGb = 0;
    while ( <GBFILE> ) {
        if($_ =~ m/LOCUS/) {
            $nLociGb++;
        }
    }
    close (GBFILE) or
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "\# " . (localtime)
        . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
        . "Could not close file $gb_file!\n");
    print LOG "\# " . (localtime)
        . ": Genbank format file $gb_file contains $nLociGb genes.\n";
    return $nLociGb;
}


####################### combine_gm_and_gth_gtf #################################
# * combine gth and genemark gtf files for creating a joined training set for
#   AUGUSTUS (note: that's apparently not a very good approach)
# * find those genes in gth.gtf that overlap on genome level with genemark.gtf
#   and print them
# * TODO: better method for joining gene sets
################################################################################

sub combine_gm_and_gth_gtf {
    my $gm_gtf = shift; # $genemarkDir/genemark.f.good.gtf
    my $gth_gff3 = shift; # $otherfilesDir/protein_alignment_$prg.gff3
    my $gth_gtf = shift; # $gthTrainGeneFile
    print LOG "\# " . (localtime) . ": Joining training genes from $gm_gtf "
        . "and $gth_gtf\n" if ($v > 2);
    my $gth_filtered_gtf = shift; # $gth_gtf.f
    my %gmGeneStarts;
    my %gmGeneStops;
    open( GMGTF, "<", $gm_gtf ) or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $gm_gtf!\n" );
    while (<GMGTF>) {
        chomp;
        my @gtfLine = split(/\t/);
        if ( scalar(@gtfLine) == 9 ) {
            my @lastCol = split( /;/, $gtfLine[8] );
            my @geneId  = split( /"/, $lastCol[1] );   # geneId[1]
            if ( $gtfLine[2] =~ m/start_codon/ ) {
                if ( $gtfLine[6] eq "+" ) {
                    $gmGeneStarts{ $geneId[1] } = $gtfLine[3];
                }
                else {
                    $gmGeneStops{ $geneId[1] } = $gtfLine[4];
                }
            }
            elsif ( $gtfLine[2] =~ m/stop_codon/ ) {
                if ( $gtfLine[6] eq "+" ) {
                    $gmGeneStops{ $geneId[1] } = $gtfLine[4];
                }
                else {
                    $gmGeneStarts{ $geneId[1] } = $gtfLine[3];
                }
            }
        }
    }
    close(GMGTF) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting,  "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $gm_gtf!\n" );
    # delete incomplete gm gene starts and stops from hashes; they will never
    # be used as training genes, anyways
    foreach (keys %gmGeneStarts){
        if(not(defined($gmGeneStops{$_}))) {
            delete $gmGeneStarts{$_};
        }
    }
    foreach (keys %gmGeneStops){
        if(not(defined($gmGeneStarts{$_}))) {
            delete $gmGeneStops{$_};
        }
    }
    open( PROTALN, "<", "$gth_gff3" ) or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $gth_gff3!\n" );
    my %gthGeneStarts;
    my %gthGeneStops;
    my $gthGeneId;
    while (<PROTALN>) {
        chomp;
        my @gtfLine = split(/\t/);
        if ( scalar(@gtfLine) == 9 ) {
            my @lastCol = split( /;/, $gtfLine[8] );
            my @geneId  = split( /=/, $lastCol[0] );   # geneId[1]
            if ( not(m/\#/) ) {
                if ( $gtfLine[2] eq "gene" ) {
                    $gthGeneId = $geneId[1];
                }
                elsif ( $gtfLine[2] eq "mRNA" ) {
                    $gthGeneStarts{ "$gtfLine[0]" . "_"
                            . $gthGeneId . "_"
                            . $geneId[1] } = $gtfLine[3];
                    $gthGeneStops{ "$gtfLine[0]" . "_"
                            . $gthGeneId . "_"
                            . $geneId[1] } = $gtfLine[4];
                }
            }
        }
    }
    close(PROTALN) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting,  "ERROR in file " . __FILE__ . " at line " . __LINE__
        . "\nCould not close file $gth_gff3!\n" );

    # read gth gtf to be filtered later
    open( GTHGTF, "<", $gth_gtf ) or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $gth_gtf!\n");
    my %gthGtf;
    while (<GTHGTF>) {
        my @gtfLine = split(/"/);
        push( @{ $gthGtf{ $gtfLine[1] } }, $_ );
    }
    close(GTHGTF) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $gth_gtf!\n");
    my %discard;
    while ( my ( $k, $v ) = each %gthGeneStarts ) {
        # check whether gene overlaps with genemark genes
        while ( my ( $gmk, $gmv ) = each %gmGeneStarts ) {
            if (( ( $v >= $gmv ) && ( $v <= $gmGeneStops{$gmk} ) ) or (   ( $gthGeneStops{$k} >= $gmv ) && ( $gthGeneStops{$k} <= $gmGeneStops{$gmk} ) ) )
            {
                $discard{$k} = 1;
                last;
            }
        }
    }
    open( FILTEREDGTH, ">", "$gth_filtered_gtf" ) or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $gth_filtered_gtf!\n");
    while ( my ( $k, $v ) = each %gthGtf ) {
        if ( not( defined( $discard{$k} ) ) ) {
            foreach ( @{$v} ) {
                print FILTEREDGTH $_;
            }
        }
    }
    open( GMGTF, "<", $gm_gtf ) or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $gm_gtf!\n" );
    while (<GMGTF>) {
        print FILTEREDGTH $_;
    }
    close (GMGTF) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $gm_gtf!\n");
    close(FILTEREDGTH) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $gth_filtered_gtf!\n");
}

####################### accuracy_calculator ####################################
# * accuracy_calculator for assessing accuracy during training AUGUSTUS
################################################################################

sub accuracy_calculator {
    my $aug_out = shift;
    print LOG "\# " . (localtime) . ": Computing accuracy of AUGUSTUS "
        ."prediction (in test file derived from predictions on training data "
        . "set stored in $aug_out)\n" if ($v > 2);
    my ( $nu_sen, $nu_sp, $ex_sen, $ex_sp, $gen_sen, $gen_sp );
    open( AUGOUT, "$aug_out" ) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nCould not open $aug_out!\n");
    while (<AUGOUT>) {
        if (/^nucleotide level\s*\|\s*(\S+)\s*\|\s*(\S+)/) {
            $nu_sen = $1;
            $nu_sp  = $2;
        }
        if (/^exon level\s*\|.*\|.*\|.*\|.*\|.*\|\s*(\S+)\s*\|\s*(\S+)/) {
            $ex_sen = $1;
            $ex_sp  = $2;
        }
        if (/^gene level\s*\|.*\|.*\|.*\|.*\|.*\|\s*(\S+)\s*\|\s*(\S+)/) {
            $gen_sen = $1;
            $gen_sp  = $2;
        }
    }
    my $target
        = (   3 * $nu_sen
            + 2 * $nu_sp
            + 4 * $ex_sen
            + 3 * $ex_sp
            + 2 * $gen_sen
            + 1 * $gen_sp ) / 15;
    return $target;
}

####################### compute_flanking_region ################################
# * compute flanking region size for AUGUSTUS training genes in genbank format
################################################################################

sub compute_flanking_region {
    print LOG "\# " . (localtime) . ": Computing flanking region size for "
        . "AUGUSTUS training genes\n" if ($v > 2);
    my $gtf  = shift;
    my $size = 0;
    my %gene;
    open( GTF, "<", $gtf ) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nCould not open file $gtf!\n");
    while (<GTF>) {
        if (m/\tCDS\t/) {
            chomp;
            my @gtfLine = split(/\t/);
            $gtfLine[8] =~ m/gene_id \"(\S+)\"/;
            if( not( defined( $gene{$1}{'start'} ) ) ) {
                $gene{$1}{'start'} = min( $gtfLine[3], $gtfLine[4] );
            }elsif( $gene{$1}{'start'} > min( $gtfLine[3], $gtfLine[4] ) ) {
                $gene{$1}{'start'} = min( $gtfLine[3], $gtfLine[4] );
            }
            if( not( defined( $gene{$1}{'stop'} ) ) ) {
                $gene{$1}{'stop'} = max($gtfLine[3], $gtfLine[4]);
            }elsif( $gene{$1}{'stop'} < max( $gtfLine[3], $gtfLine[4] ) ) {
                $gene{$1}{'stop'} = max( $gtfLine[3], $gtfLine[4] );
            }
        }
    }
    close(GTF) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        ."\nCould not close file $gtf!\n");
    my $nGenes   = 0;
    my $totalLen = 0;
    my $avLen    = 0;
    foreach my $key ( keys %gene ) {
        $nGenes++;
        $totalLen += $gene{$key}{'stop'} - $gene{$key}{'start'} +1
    }
    $avLen = $totalLen / $nGenes;
    $size = min( ( floor( $avLen / 2 ), 10000 ) );
    if ( $size < 0 ) {
        print LOG "#*********\n"
                . "# WARNING: \$flanking_DNA has the value $size , which is "
                . "smaller than 0. Something must have gone wrong, there. "
                . "Replacing by value 10000.\n"
                . "#*********\n" if ($v > 0);
        $size = 10000;
    }
    return $size;
}

####################### gtf2gb #################################################
# * convert gtf and genome file to genbank file for training AUGUSTUS
################################################################################

sub gtf2gb {
    my $gtf = shift;
    print LOG "\# " . (localtime) . ": Converting gtf file $gtf to genbank "
        . "file\n" if ($v > 2);
    my $gb  = shift;
    if( not( defined( $flanking_DNA ) ) ) {
        $flanking_DNA = compute_flanking_region($gtf);
    }
    $string       = find(
        "gff2gbSmallDNA.pl",    $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    if ( !uptodate( [ $genome, $gtf ], [$gb] ) || $overwrite ) {
        my @pathName = split( /\//, $gtf );
        $errorfile
            = "$errorfilesDir/"
            . $pathName[ ( scalar(@pathName) - 1 ) ]
            . "_gff2gbSmallDNA.stderr";
        if ( -z $gtf ) {
            $prtStr
                = "\# "
                . (localtime)
                . " ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "The training gene file $gtf file is empty!\n";
            print LOG $prtStr;
            print STDERR $prtStr;
            exit(1);
        }
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString
            .= "perl $string $gtf $genome $flanking_DNA $gb 2>$errorfile";
        print LOG "\# " . (localtime) . ": create genbank file $gb\n"
            if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nFailed to execute: $perlCmdString\n");
        print LOG "#*********\n"
                . "# INFORMATION: the size of flanking region used in this "
                . "BRAKER run is $flanking_DNA".". You might need this "
                . "value if you later add a UTR training on top of an "
                . "already existing BRAKER run.\n"
                . "#*********\n" if ($v > 0);
    }
}

####################### augustus ###############################################
# * predict genes with AUGUSTUS
# * ab initio, if enabled
# * with hints
#   if RNA-Seq and protein hints, two separate AUGUSTUS runs are performed
#   1) RNA-Seq only
#   2) RNA-Seq and protein (with higher weight on protein)
#   subsequently, prediction sets are joined with joingenes
# * with ep hints (RNA-Seq) and all other hints and UTR parameters
################################################################################

sub augustus {
    my $localUTR = shift;
    my $genesetId = "";
    if( $localUTR eq "on" ) {
        $genesetId = "_utr";
    }
    print LOG "\# " . (localtime) . ": RUNNING AUGUSTUS\n" if ($v > 2);

    print CITE $pubs{'aug-cdna'}; $pubs{'aug-cdna'} = "";
    print CITE $pubs{'aug-hmm'}; $pubs{'aug-hmm'} = "";

    $augpath = "$AUGUSTUS_BIN_PATH/augustus";
    my @genome_files;
    my $genome_dir = "$otherfilesDir/genome_split";
    my $augustus_dir           = "$otherfilesDir/augustus_tmp$genesetId";
    my $augustus_dir_ab_initio = "$otherfilesDir/augustus_ab_initio_tmp$genesetId";

    if( $CPU > 1 ) {
        prepare_genome( $genome_dir );
    }

    if( $ESmode == 1 || defined($ab_initio)) {
        if( !uptodate( [$genome], 
            ["$otherfilesDir/augustus.ab_initio$genesetId.gtf"] ) 
        || $overwrite ){
            if( $CPU > 1) {
                make_ab_initio_jobs( $augustus_dir_ab_initio, $genome_dir,
                    $localUTR, $genesetId );
                run_augustus_jobs( "$otherfilesDir/ab_initio$genesetId.job.lst" );
                join_aug_pred( $augustus_dir_ab_initio,
                    "$otherfilesDir/augustus.ab_initio$genesetId.gff" );
            } else {
                run_augustus_single_core_ab_initio( $localUTR , $genesetId);
            }
            make_gtf("$otherfilesDir/augustus.ab_initio$genesetId.gff");
            if(not($skip_fixing_broken_genes)){
                get_anno_fasta("$otherfilesDir/augustus.ab_initio".$genesetId.".gtf", $genesetId."tmp");
                if(-e "$otherfilesDir/bad_genes.lst"){
                    fix_ifs_genes("augustus.ab_initio".$genesetId, 
                                  "$otherfilesDir/augustus.ab_initio".$genesetId.".gtf", 
                                  $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                                  $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                                  $AUGUSTUS_SCRIPTS_PATH);
                }
            }
            get_anno_fasta("$otherfilesDir/augustus.ab_initio".$genesetId.".gtf", $genesetId);

        } else {
            print LOG "\# " . (localtime) . ": Skipping predicting genes with "
                . "AUGUSTUS ab initio because file "
                . "$otherfilesDir/augustus.ab_initio$genesetId.gtf is up to "
                . "date.\n" if ($v > 3);
        }
    }

    if( ! $ESmode == 1 ) {
        if (!uptodate( [ $extrinsicCfgFile, $hintsfile, $genome ],
            ["$otherfilesDir/augustus.hints$genesetId.gtf"] ) || $overwrite)
        {
            if ( $CPU > 1 ) {
                # single ex.cfg scenarios are:
                # EPmode == 1 -> ep.cfg
                # EPmode == 0 && !prg -> rnaseq.cfg
                # trainFromGth -> gth.cfg
                if ( ($foundProt>0 && $foundRNASeq==0) || ($foundProt==0 && $foundRNASeq > 0)) {
                    if(defined($extrinsicCfgFile1) && $localUTR eq "off"){
                        $extrinsicCfgFile = $extrinsicCfgFile1;
                    }elsif(defined($extrinsicCfgFile2) && $localUTR eq "on"){
                        $extrinsicCfgFile = $extrinsicCfgFile2;
                    }else{
                        if ( $foundProt>0 && $foundRNASeq==0 ){
                            if(defined($prg)){
                                if ( $prg eq "gth" || $prg eq "exonerate" || $prg eq "spaln" || $prg eq "gemoma") {
                                    if( $localUTR eq "off" ) {
                                        assign_ex_cfg ("gth.cfg");
                                    }else{
                                        assign_ex_cfg ("gth_utr.cfg")
                                    }
                                }elsif($EPmode==1){
                                    if( $localUTR eq "off" ) {
                                        assign_ex_cfg ("ep.cfg");
                                    }else{
                                        assign_ex_cfg ("ep_utr.cfg");
                                    }

                                }else{
                                    $prtStr = "\# " . (localtime) . ": ERROR in file " . __FILE__
                                        ." at line " . __LINE__
                                        . "\nunsupported alignment program $prg given!\n";
                                    print STDERR $prtStr;
                                    print LOG $prtStr;
                                }
                            }
                        }elsif( $foundProt==0 && $foundRNASeq > 0){
                            if( $localUTR eq "off" ) {
                                assign_ex_cfg ("rnaseq.cfg");
                            }else{
                                assign_ex_cfg ("rnaseq_utr.cfg");
                            }
                        }
                    }
                    copy_ex_cfg($extrinsicCfgFile, "ex1$genesetId.cfg");
                    my $hintId = "hints".$genesetId;
                    make_hints_jobs( $augustus_dir, $genome_dir, $hintsfile,
                        $extrinsicCfgFile, $localUTR, $hintId );
                    run_augustus_jobs( "$otherfilesDir/$hintId.job.lst" );
                    join_aug_pred( $augustus_dir, "$otherfilesDir/augustus.$hintId.gff" );
                    make_gtf("$otherfilesDir/augustus.$hintId.gff");
                    if(not($skip_fixing_broken_genes)){
                        get_anno_fasta("$otherfilesDir/augustus.$hintId.gtf", "tmp");
                        if(-e "$otherfilesDir/bad_genes.lst"){
                            fix_ifs_genes("augustus.$hintId", 
                                  "$otherfilesDir/augustus.$hintId.gtf", 
                                  $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                                  $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                                  $AUGUSTUS_SCRIPTS_PATH, $hintsfile, $extrinsicCfgFile);
                        }
                    }
                    get_anno_fasta("$otherfilesDir/augustus.$hintId.gtf", $hintId);
                    clean_aug_jobs($hintId);
                }else{
                    run_augustus_with_joingenes_parallel($genome_dir, $localUTR, $genesetId);
                }
            } else {
                push( @genome_files, $genome );
                if ( ($foundProt>0 && $foundRNASeq==0) || ($foundProt==0 && $foundRNASeq > 0)) {
                    if(defined($extrinsicCfgFile1) && $localUTR eq "off"){
                        $extrinsicCfgFile = $extrinsicCfgFile1;
                    }elsif(defined($extrinsicCfgFile2) && $localUTR eq "on"){
                        $extrinsicCfgFile = $extrinsicCfgFile2;
                    }else{
                        if ( ($foundProt>0 && $foundRNASeq==0) ){
                            if (defined ($prg) || $EPmode == 1) {
                                if ( $prg eq "gth" || $prg eq "exonerate" || $prg eq "spaln" || $prg eq "gemoma") {
                                    if ( $localUTR eq "off" ) {
                                        assign_ex_cfg ("gth.cfg");
                                    }else{
                                        assign_ex_cfg ("gth_utr.cfg");
                                    }
                                }elsif($EPmode == 1){
                                    if( $localUTR eq "off" ) {
                                        assign_ex_cfg ("ep.cfg");
                                    }else{
                                        assign_ex_cfg ("ep_utr.cfg");
                                    }
                                }else{
                                    $prtStr = "\# " . (localtime) . ": ERROR in file " . __FILE__
                                        ." at line " . __LINE__
                                        . "\nunsupported alignment program $prg given!\n";
                                    print STDERR $prtStr;
                                    print LOG $prtStr;
                                }
                            }
                        }elsif( $foundProt==0 && $foundRNASeq > 0) {
                            if($localUTR eq "off") {
                                assign_ex_cfg ("rnaseq.cfg");
                            }else{
                                assign_ex_cfg ("rnaseq_utr.cfg");
                            }
                        }
                    }
                    my $hintId = "hints".$genesetId;
                    copy_ex_cfg($extrinsicCfgFile, "ex1$genesetId.cfg");
                    run_augustus_single_core_hints( $hintsfile, $extrinsicCfgFile,
                        $localUTR, $hintId);
                    make_gtf("$otherfilesDir/augustus.$hintId.gff");
                    if(not($skip_fixing_broken_genes)){
                        get_anno_fasta("$otherfilesDir/augustus.$hintId.gtf", "tmp");
                        if(-e "$otherfilesDir/bad_genes.lst"){
                            fix_ifs_genes("augustus.$hintId", 
                                  "$otherfilesDir/augustus.$hintId.gtf", 
                                  $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                                  $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                                  $AUGUSTUS_SCRIPTS_PATH, $hintsfile, $extrinsicCfgFile);
                        }
                    }
                    get_anno_fasta("$otherfilesDir/augustus.$hintId.gtf", $hintId);
                }else{
                    run_augustus_with_joingenes_single_core($localUTR, $genesetId);
                }
            }
            print LOG "\# " . (localtime) . ": AUGUSTUS prediction complete\n"
                if ($v > 3);

        }
    }
}

####################### assign_ex_cfg ##########################################
# * predict genes with AUGUSTUS
# * ab initio, if enabled
# * with hints
#   if RNA-Seq and protein hints, two separate AUGUSTUS runs are performed
#   1) RNA-Seq only
#   2) RNA-Seq and protein (with higher weight on protein)
#   subsequently, prediction sets are joined with joingenes
################################################################################

sub assign_ex_cfg {
    my $thisCfg = shift;
    $string = find( "cfg/".$thisCfg, $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH,
        $AUGUSTUS_CONFIG_PATH );
    if ( -e $string ) {
        $extrinsicCfgFile = $string;
    }
    else {
        $prtStr = "#*********\n"
                . "# WARNING: tried to assign extrinsicCfgFile $thisCfg as "
                . "$string but this file does not seem to exist.\n"
                . "#*********\n";
        $logString .= $prtStr if ($v > 0);
        $extrinsicCfgFile = undef;
    }
}

####################### prepare_genome #########################################
# * split genome for parallel AUGUSTUS execution
################################################################################

sub prepare_genome {
    my $augustus_dir = shift;
    # check whether genome has been split, already, cannot use uptodate because
    # name of resulting files is unknown before splitting genome file
    my $foundFastaFile;
    if( -d $augustus_dir ) {
        opendir(DIR, $augustus_dir) or die ("ERROR in file " . __FILE__
            . " at line ". __LINE__
            . "\nFailed to open directory $augustus_dir!\n");
        while(my $f = readdir(DIR)) {
            if($f =~ m/\.fa$/) {
                $foundFastaFile = 1;
            }
        }
        closedir(DIR)
    }

    if( not( $foundFastaFile ) || $overwrite ) {
        # if augustus_dir already has contents, this leads to problems with
        # renaming fasta files, therefore delete the entire directory in case
        # of $overwrite
        if( $overwrite && -d $augustus_dir ) {
            rmtree( $augustus_dir ) or die ("ERROR in file " . __FILE__
            . " at line ". __LINE__
            . "\nFailed recursively delete directory $augustus_dir!\n");
        }

        print LOG "\# " . (localtime) . ": Preparing genome for running "
            . "AUGUSTUS in parallel\n" if ($v > 2);

        if ( not( -d $augustus_dir ) ) {
            print LOG "\# "
                . (localtime)
                . ": Creating directory for storing AUGUSTUS files (hints, "
                . "temporarily) $augustus_dir.\n" if ($v > 3);
            mkdir $augustus_dir or die ("ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to create directory $augustus_dir!\n");
        }
        print LOG "\# "
            . (localtime)
            . ": splitting genome file in smaller parts for parallel execution of "
            . "AUGUSTUS prediction\n" if ($v > 3);
        $string = find(
            "splitMfasta.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
        $errorfile = "$errorfilesDir/splitMfasta.stderr";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString
            .= "perl $string $genome --outputpath=$augustus_dir 2>$errorfile";
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $perlCmdString\n");

        # rename files according to scaffold name
        $cmdString = "cd $augustus_dir; for f in genome.split.*; "
                   . "do NAME=`grep \">\" \$f`; mv \$f \${NAME#>}.fa; "
                   . "done; cd ..\n";
        print LOG $cmdString if ($v > 3);
        system("$cmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
        my @genome_files = `ls $augustus_dir`;
        print LOG "\# " . (localtime) . ": Split genome file in "
        . scalar(@genome_files) . " parts, finished.\n" if ($v > 3);
    }else{
        print LOG "\# " . (localtime) . ": Skipping splitMfasta.pl because "
            . "genome file has already been split.\n" if ($v > 3);
    }
}

####################### make_hints_jobs ########################################
# * make AUGUSTUS hints jobs (parallelization)
################################################################################

sub make_hints_jobs{
    my $augustus_dir = shift;
    my $genome_dir = shift;
    my $thisHintsfile = shift;
    my $cfgFile = shift;
    my $localUTR = shift;
    my $hintId = shift;
    if( !uptodate([$genome, $thisHintsfile], ["$otherfilesDir/aug_$hintId.lst"] 
        ) || $overwrite ) {
        print LOG "\# " . (localtime) . ": Making AUGUSTUS jobs with hintsfile "
            . "$thisHintsfile, cfgFile $cfgFile, UTR status $localUTR, and hintId "
            . "$hintId\n" if ($v > 2);
        my @genome_files = `ls $genome_dir`;
        my %scaffFileNames;
        foreach (@genome_files) {
            chomp;
            $_ =~ m/(.*)\.\w+$/;
            $scaffFileNames{$1} = "$genome_dir/$_";
        }  
        if ( not( -d $augustus_dir ) && $CPU > 1) {
            print LOG "\# " . (localtime)
                . ": Creating directory for storing AUGUSTUS files (hints, "
                . "temporarily) $augustus_dir.\n" if ($v > 3);
            mkdir $augustus_dir or die ("ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to create directory $augustus_dir!\n");
        }
        print LOG "\# "
            . (localtime)
            . ": creating $otherfilesDir/aug_$hintId.lst for AUGUSTUS jobs\n" 
            if ($v > 3);
        open( ALIST, ">", "$otherfilesDir/aug_$hintId.lst" )
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $otherfilesDir/aug_$hintId.lst!\n");
        # make list for creating augustus jobs
        while ( my ( $locus, $size ) = each %scaffSizes ) {
            print ALIST "$scaffFileNames{$locus}\t$thisHintsfile\t1\t$size\n";
        }
        close(ALIST) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $otherfilesDir/aug_$hintId.lst!\n");
    }else{
        print LOG "\# " . (localtime) . ": Skip making AUGUSTUS job list file "
            . " with hintsfile $thisHintsfile and hintId $hintId because "
            . "$otherfilesDir/aug_$hintId.lst is up to date.\n" if ($v > 3);
    }
    if( !uptodate(["$otherfilesDir/aug_$hintId.lst"], 
        ["$otherfilesDir/$hintId.job.lst"]) || $overwrite ) {
        print LOG "\# " . (localtime)
            . ": creating AUGUSTUS jobs (with $hintId)\n" if ($v > 3);
        $string = find(
            "createAugustusJoblist.pl", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH,     $AUGUSTUS_CONFIG_PATH );
        $errorfile = "$errorfilesDir/createAugustusJoblist_$hintId.stderr";
        $perlCmdString = "";
        $perlCmdString .= "cd $otherfilesDir\n";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string --sequences=$otherfilesDir/aug_$hintId.lst --wrap=\"#!/bin/bash\" --overlap=5000 --chunksize=$chunksize --outputdir=$augustus_dir "
                       .  "--joblist=$otherfilesDir/$hintId.job.lst --jobprefix=aug_".$hintId."_ --partitionHints --command \"$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                       .  "--extrinsicCfgFile=$cfgFile --alternatives-from-evidence=$alternatives_from_evidence --UTR=$localUTR --exonnames=on --codingseq=on "
                       .  "--allow_hinted_splicesites=gcag,atac ";
        if ( defined($optCfgFile) ) {
            $perlCmdString .= " --optCfgFile=$optCfgFile";
        }
        if ($soft_mask) {
            $perlCmdString .= " --softmasking=1";
        }
        if ($augustus_args) {
            $perlCmdString .= " $augustus_args";
        }
        $perlCmdString .= "\" 2>$errorfile\n";
        $perlCmdString .= "cd ..\n";
        print LOG "$perlCmdString" if ($v > 3);
        system("$perlCmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nFailed to execute: $perlCmdString\n");
    }else{
        print LOG "\# " . (localtime) . ": Skip making AUGUSTUS jobs with "
            . "hintsfile $thisHintsfile and hintId $hintId because "
            . "$otherfilesDir/$hintId.job.lst is up to date.\n" if ($v > 3);
    }
}

####################### make_ab_initio_jobs ####################################
# * make AUGUSTUS ab initio jobs (parallelization)
################################################################################

sub make_ab_initio_jobs{
    my $augustus_dir_ab_initio = shift;
    my $augustus_dir = shift;
    my $localUTR = shift;
    my $genesetId = shift;
    if( !uptodate( [$genome], ["$otherfilesDir/augustus_ab_initio.lst"])
        || $overwrite ) {
        print LOG "\# " . (localtime) . ": Creating AUGUSTUS ab initio jobs\n"
            if ($v > 2);
        my @genome_files = `ls $augustus_dir`;
        my %scaffFileNames;
        foreach (@genome_files) {
            chomp;
            $_ =~ m/(.*)\.\w+$/;
            $scaffFileNames{$1} = "$augustus_dir/$_";
        }
        if ( not( -d $augustus_dir_ab_initio ) && $CPU > 1) {
            print LOG "\# " . (localtime)
                . ": Creating directory for storing AUGUSTUS files (ab initio, "
                . "temporarily) $augustus_dir_ab_initio.\n" if ($v > 3);
            mkdir $augustus_dir_ab_initio or die ("ERROR in file " . __FILE__
                . " at line ". __LINE__
                ."\nFailed to create directory $augustus_dir_ab_initio!\n");
        }
        print LOG "\# " . (localtime)
            . ": creating $otherfilesDir/aug_ab_initio.lst for AUGUSTUS jobs\n"
            if ($v > 3);
        open( ILIST, ">", "$otherfilesDir/aug_ab_initio.lst" )
            or die(
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $otherfilesDir/aug_ab_initio.lst!\n" );
        while ( my ( $locus, $size ) = each %scaffSizes ) {
            print ILIST "$scaffFileNames{$locus}\t1\t$size\n";
        }
        close(ILIST) or die(
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            ."\nCould not close file $otherfilesDir/aug_ab_initio.lst!\n" );
    } else {
        print LOG "\# " . (localtime)
            . ": Using existing file  $otherfilesDir/aug_ab_initio.lst\n"
            if ($v > 3);
    }

    if( !uptodate(["$otherfilesDir/aug_ab_initio.lst"], 
        ["$otherfilesDir/ab_initio$genesetId.job.lst"]) || $overwrite ) {
        $string = find(
            "createAugustusJoblist.pl", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH,     $AUGUSTUS_CONFIG_PATH);
        $errorfile
        = "$errorfilesDir/createAugustusJoblist_ab_initio$genesetId.stderr";

        $perlCmdString = "";
        $perlCmdString = "cd $otherfilesDir\n";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string "
                       .  "--sequences=$otherfilesDir/aug_ab_initio.lst "
                       .  "--wrap=\"#!/bin/bash\" --overlap=5000 "
                       .  "--chunksize=$chunksize "
                       .  "--outputdir=$augustus_dir_ab_initio "
                       .  "--joblist=$otherfilesDir/ab_initio$genesetId.job.lst "
                       .  "--jobprefix=aug_ab_initio_ "
                       .  "--command \"$augpath --species=$species "
                       .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                       .  "--UTR=$localUTR  --exonnames=on --codingseq=on ";
        if ($soft_mask) {
            $perlCmdString .= " --softmasking=1";
        }
        $perlCmdString .= "\" 2>$errorfile\n";
        $perlCmdString .= "cd ..\n";
        print LOG "$perlCmdString" if ($v > 3);
        system("$perlCmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $perlCmdString\n");
    }else{
        print LOG "\# " . (localtime)
            . ": Skipping creation of AUGUSTUS ab inito jobs because they "
            . "already exist ($otherfilesDir/ab_initio$genesetId.job.lst).\n"
            if ($v > 3);
    }
}

####################### run_augustus_jobs ######################################
# * run parallel AUGUSTUS jobs (ForkManager)
################################################################################

sub run_augustus_jobs {
    my $jobLst = shift;
    print LOG "\# " . (localtime) . ": Running AUGUSTUS jobs from $jobLst\n" 
        if ($v > 2);
    my $pm = new Parallel::ForkManager($CPU);
    my $cJobs = 0;
    open( AIJOBS, "<", $jobLst )
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $jobLst!\n");
    my @aiJobs;
    while (<AIJOBS>) {
        chomp;
        push @aiJobs, "$otherfilesDir/$_";
    }
    close(AIJOBS)
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $jobLst!\n");
    foreach(@aiJobs){
        $cJobs++;
        print LOG "\# " . (localtime) . ": Running AUGUSTUS job $cJobs\n" 
            if ($v > 3);
        $cmdString = "$_";
        print LOG "$cmdString\n" if ($v > 3);
        my $pid = $pm->start and next;
        system("$cmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString!\n");
        $pm->finish;
    }
    $pm->wait_all_children;
}

####################### join_aug_pred ##########################################
# * join AUGUSTUS predictions from parallelized job execution
################################################################################

sub join_aug_pred {
    my $pred_dir    = shift;
    print LOG "\# " . (localtime) . ": Joining AUGUSTUS predictions in "
        . "directory $pred_dir\n" if ($v > 2);
    my $target_file = shift;
    $string = find(
        "join_aug_pred.pl",     $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    my $cat_file;
    if(-e "$otherfilesDir/augustus.tmp1.gff"){
        $cat_file = "$otherfilesDir/augustus.tmp2.gff";
    }else{
        $cat_file = "$otherfilesDir/augustus.tmp1.gff";
    }
    my @t = split(/\//, $pred_dir);
    $t[scalar(@t)-1] =~ s/\///;
    my $error_cat_file = "$errorfilesDir/augustus_".$t[scalar(@t)-1].".err";
    print LOG "\# " . (localtime)
        . ": Concatenating AUGUSTUS output files in $pred_dir\n" if ($v > 3);
    opendir( DIR, $pred_dir ) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to open directory $pred_dir!\n");
    # need to concatenate gff files in the correct order along chromosomes for
    # join_aug_pred.pl
    my %gff_files;
    my %err_files;
    while ( my $file = readdir(DIR) ) {
        my %fileinfo;
        if ( $file =~ m/\d+\.\d+\.(.*)\.(\d+)\.\.\d+\.gff/ ) {
            $fileinfo{'start'} = $2;
            $fileinfo{'filename'} = $file;
            push @{$gff_files{$1}}, \%fileinfo;
        }elsif ( $file =~ m/\d+\.\d+\.(.*)\.(\d+)\.\.\d+\.err/ ){
            $fileinfo{'start'} = $2;
            $fileinfo{'filename'} = $file;
            push @{$err_files{$1}}, \%fileinfo;
        }
    }
    foreach(keys %gff_files){
        @{$gff_files{$_}} = sort { $a->{'start'} <=> $b->{'start'}} @{$gff_files{$_}};
    }
    foreach(keys %err_files){
        @{$gff_files{$_}} = sort { $a->{'start'} <=> $b->{'start'}} @{$gff_files{$_}};
    }
    foreach(keys %gff_files){
        foreach(@{$gff_files{$_}}){
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "cat $pred_dir/".$_->{'filename'}." >> $cat_file";
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0 or die("ERROR in file " . __FILE__
                . " at line ". __LINE__ ."\nFailed to execute $cmdString\n");
        }
    }
    foreach(keys %err_files){
        foreach(@{$err_files{$_}}){
            if ( -s $_ ) {
                $cmdString = "echo \"Contents of file ".$_->{'filename'}."\" >> $error_cat_file";
                print LOG "$cmdString\n" if ($v > 3);
                system ("$cmdString") == 0 or die ("ERROR in file " . __FILE__
                    ." at line ". __LINE__ ."\nFailed to execute $cmdString\n");
                $cmdString = "";
                if ($nice) {
                    $cmdString .= "nice ";
                }
                $cmdString .= "cat $pred_dir/".$_->{'filename'}." >> $error_cat_file";
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0 or die("ERROR in file " . __FILE__
                    ." at line ". __LINE__ ."\nFailed to execute $cmdString\n");
            }
        }
    }

    closedir(DIR) or die ("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to close directory $pred_dir\n");

    $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    $perlCmdString .= "perl $string < $cat_file > $target_file";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            ."\nFailed to execute $perlCmdString\n");
    if($cleanup){
        print LOG "\# " . (localtime) . ": Deleting $pred_dir\n" if ($v > 3);
        rmtree( ["$pred_dir"] ) or die ("ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nFailed to delete $pred_dir!\n");
        print LOG "\# " . (localtime) . ": Deleting $cat_file\n" if ($v > 3);
        unlink($cat_file);
    }
}

####################### run_augustus_single_core_ab_initio #####################
# * run AUGUSTUS ab initio on a single core
################################################################################

sub run_augustus_single_core_ab_initio {
    my $localUTR = shift;
    my $genesetId = shift;
    my $aug_ab_initio_err = "$errorfilesDir/augustus.ab_initio$genesetId.err";
    my $aug_ab_initio_out = "$otherfilesDir/augustus.ab_initio$genesetId.gff";
    $cmdString         = "";
    if ($nice) {
        $cmdString .= "nice ";
    }
    $cmdString .= "$augpath --species=$species "
               .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
               .  "--UTR=$localUTR --exonnames=on --codingseq=on";
    if ($soft_mask) {
        $cmdString .= " --softmasking=1";
    }
    $cmdString .= " $genome 1>$aug_ab_initio_out 2>$aug_ab_initio_err";
    print LOG "\# "
        . (localtime)
        . ": Running AUGUSTUS in ab initio mode for file $genome with "
        . "gensetsetId $genesetId.\n" if ($v > 2);
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString!\n");
}

####################### run_augustus_single_core_hints #########################
# * run AUGUSTUS with hints on a single core (hints from a single source)
################################################################################

sub run_augustus_single_core_hints {
    my $thisHintsfile = shift;
    my $cfgFile = shift;
    my $localUTR = shift;
    my $hintId = shift;
    my $aug_hints_err = "$errorfilesDir/augustus.$hintId.stderr";
    my $aug_hints_out = "$otherfilesDir/augustus.$hintId.gff";
    $cmdString     = "";
    if ($nice) {
        $cmdString .= "nice ";
    }
    $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH --extrinsicCfgFile=$cfgFile --alternatives-from-evidence=$alternatives_from_evidence "
               .  "--hintsfile=$thisHintsfile --UTR=$localUTR --exonnames=on --codingseq=on --allow_hinted_splicesites=gcag,atac";
    if ( defined($optCfgFile) ) {
        $cmdString .= " --optCfgFile=$optCfgFile";
    }
    if ($soft_mask) {
        $cmdString .= " --softmasking=1";
    }
    if ( defined($augustus_args) ) {
        $cmdString .= " $augustus_args";
    }
    $cmdString .= " $genome 1>$aug_hints_out 2>$aug_hints_err";
    print LOG "\# "
        . (localtime)
        . ": Running AUGUSTUS with $hintId for file $genome\n" if ($v > 2);
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString!\n");
}

####################### adjust_pri #############################################
# * adjust priorities in hints files
################################################################################

sub adjust_pri {
    print LOG "\# " . (localtime) . ": Adjusting priority for protein hints for "
        . "running AUGUSTUS with RNA-Seq and protein hints simultaneously\n"
        if ($v > 2);
    my $hints = shift;
    my $adjusted = shift;
    my $source = shift;
    my $value = shift;
    open ( HINTS, "<", $hints ) or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nCould not open file $hints!\n");
    open (OUT, ">", $adjusted) or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nCould not open file $adjusted!\n");
    while(<HINTS>){
        if ( $_ =~ m/src=E/ ) {
            $_ =~ s/pri=(\d)/pri=4/;
            print OUT $_;
        }elsif ( $_ =~ m/src=P/ ) {
            $_ =~ s/pri=(\d)/pri=5/;
            print OUT $_;
        }else{
            print OUT $_;
        }
    }
    close (OUT) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $adjusted!\n");
    close (HINTS) or die ("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $hints!\n");
}

####################### get_rnaseq_hints #######################################
# * get RNA-Seq only hints for running AUGUSTUS with RNA-Seq & manual only
################################################################################

sub get_rnaseq_hints {
    print LOG "\# " . (localtime) . ": Retrieving RNA-Seq hints for running "
        . "AUGUSTUS with RNA-Seq hints only (also using manual hints)\n" if ($v > 2);
    my $hints = shift;
    my $adjusted = shift;
    open ( HINTS, "<", $hints ) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nCould not open file $hints!\n");
    open (OUT, ">", $adjusted) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nCould not open file $adjusted!\n");
    while(<HINTS>){
        if ( ($_ =~ m/src=E/) || ($_ =~ m/src=M/) ) {
            print OUT $_;
        }
    }
    close (OUT) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $adjusted!\n");
    close (HINTS) or die ("ERROR in file " . __FILE__ ." at line ". __LINE__
        ."\nCould not close file $hints!\n");
}

####################### run_augustus_with_joingenes_parallel ###################
# * run AUGUSTUS with joingenes, parallelized
# * means: execute RNA-Seq only predictions
#          execute RNA-Seq & protein predictions (giving proteins higher weight)
#          joining predictions
#          adding genes missed by joingenes to final gene set
################################################################################

sub run_augustus_with_joingenes_parallel {
    print LOG "\# " . (localtime) . ": Running AUGUSTUS with joingenes in "
        . "parallel mode\n" if ($v > 2);
    my $genome_dir = shift;
    my $localUTR = shift;
    my $genesetId = shift;
    # if RNASeq and protein hints are given
    my $adjustedHintsFile = "$hintsfile.Ppri5";
    if( !uptodate( [$hintsfile], [$adjustedHintsFile]) || $overwrite ) {    
        if( ! $ETPmode ) {
            $cmdString = "cp $hintsfile $adjustedHintsFile";
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0 or die("ERROR in file " . __FILE__
                . " at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
        }else{
            # evidence.gff hints are included in $hintsfile
            adjust_pri( $hintsfile, $adjustedHintsFile, "P", 5);
        }
    } else {
        print LOG "\# " . (localtime) . " Skip creating adjusted hints file "
            . "$adjustedHintsFile because it is up to date.\n" if($v > 3);
    }

    if( defined ($extrinsicCfgFile1) && $localUTR eq "off") {
        $extrinsicCfgFile = $extrinsicCfgFile1;
    }elsif(defined ($extrinsicCfgFile3) && $localUTR eq "on"){
        $extrinsicCfgFile = $extrinsicCfgFile3;
    }else{
        if( $localUTR eq "off" ) {
            assign_ex_cfg("ep.cfg");
        }else{
            assign_ex_cfg("ep_utr.cfg");
        }
    }
    copy_ex_cfg($extrinsicCfgFile, "ex1$genesetId.cfg");
    my $augustus_dir = "$otherfilesDir/augustus_tmp_Ppri5$genesetId";
    make_hints_jobs( $augustus_dir, $genome_dir, $adjustedHintsFile,
        $extrinsicCfgFile, $localUTR, "Ppri5", $genesetId);
    run_augustus_jobs( "$otherfilesDir/Ppri5$genesetId.job.lst" );
    join_aug_pred( $augustus_dir, "$otherfilesDir/augustus.Ppri5$genesetId.gff" );
    make_gtf("$otherfilesDir/augustus.Ppri5$genesetId.gff");
    if(not($skip_fixing_broken_genes)){
        get_anno_fasta("$otherfilesDir/augustus.Ppri5$genesetId.gtf", "tmp");
        if(-e "$otherfilesDir/bad_genes.lst"){
            fix_ifs_genes("augustus.Ppri5$genesetId", 
                          "$otherfilesDir/augustus.Ppri5$genesetId.gtf", 
                          $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                          $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                          $AUGUSTUS_SCRIPTS_PATH, $adjustedHintsFile, $extrinsicCfgFile);
        }
    }
    clean_aug_jobs("Ppri5$genesetId");
    $adjustedHintsFile = "$hintsfile.E";
    # the following includes evidence hints
    get_rnaseq_hints($hintsfile, $adjustedHintsFile);
    if (defined ($extrinsicCfgFile2) && $localUTR eq "off") {
        $extrinsicCfgFile = $extrinsicCfgFile2;
    }elsif(defined ($extrinsicCfgFile4) && $localUTR eq "on"){
        $extrinsicCfgFile = $extrinsicCfgFile4;
    }elsif($localUTR eq "off"){
        assign_ex_cfg("rnaseq.cfg");
    }else{
        assign_ex_cfg("rnaseq_utr.cfg");
    }
    copy_ex_cfg($extrinsicCfgFile, "ex2$genesetId.cfg");
    $augustus_dir = "$otherfilesDir/augustus_tmp_E$genesetId";
    make_hints_jobs( $augustus_dir, $genome_dir, $adjustedHintsFile,
        $extrinsicCfgFile, $localUTR, "E", $genesetId);
    run_augustus_jobs( "$otherfilesDir/E$genesetId.job.lst" );
    join_aug_pred( $augustus_dir, "$otherfilesDir/augustus.E$genesetId.gff" );
    make_gtf("$otherfilesDir/augustus.E$genesetId.gff");
    if(not($skip_fixing_broken_genes)){
        get_anno_fasta("$otherfilesDir/augustus.E$genesetId.gtf", "tmp");
        if(-e "$otherfilesDir/bad_genes.lst"){
            fix_ifs_genes("augustus.E$genesetId", 
                          "$otherfilesDir/augustus.E$genesetId.gtf", 
                          $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                          $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                          $AUGUSTUS_SCRIPTS_PATH, $adjustedHintsFile, $extrinsicCfgFile);
        }
    }
    clean_aug_jobs("E$genesetId");
    joingenes("$otherfilesDir/augustus.Ppri5$genesetId.gtf",
        "$otherfilesDir/augustus.E$genesetId.gtf", $genesetId);
}

####################### run_augustus_with_joingenes_single_core ################
# * run AUGUSTUS with joingenes on a single core
# * means: execute RNA-Seq only predictions
#          execute RNA-Seq & protein predictions (giving proteins higher weight)
#          joining predictions
#          adding genes missed by joingenes to final gene set
################################################################################

sub run_augustus_with_joingenes_single_core {
    print LOG "\# " . (localtime) . ": Running AUGUSTUS with joingenes in "
        . "single core mode\n" if ($v > 2);
    my $localUTR = shift;
    my $genesetId = shift;
    # if RNASeq and protein hints are given
    my $adjustedHintsFile = "$hintsfile.Ppri5";
    if( !uptodate([$hintsfile],[$adjustedHintsFile]) || $overwrite ) {
        if( ! $ETPmode ) {
            $cmdString = "cp $hintsfile $adjustedHintsFile";
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0 or die("ERROR in file " . __FILE__
                . " at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
        }else{
            adjust_pri( $hintsfile, $adjustedHintsFile, "P", 5);
        }
        if ( $ETPmode == 1 && (-e  "$otherfilesDir/evidence.gff" )) {
            $cmdString = "cat $otherfilesDir/evidence.gff >> $adjustedHintsFile";
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0 or die("ERROR in file " . __FILE__
                . " at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
        }
    } else {
        print LOG "\# " . (localtime) . ": Skip making adjusted hints file "
            . "$adjustedHintsFile from hintsfile $hintsfile because file is up "
            . "to date.\n" if ($v > 3);
    }

    if( !uptodate( [$adjustedHintsFile], 
        ["$otherfilesDir/augustus.Ppri5$genesetId.gff"] ) || $overwrite ) {
        if( defined ($extrinsicCfgFile1) && $localUTR eq "off") {
            $extrinsicCfgFile = $extrinsicCfgFile1;
        }elsif(defined ($extrinsicCfgFile3) && $localUTR eq "on"){
            $extrinsicCfgFile = $extrinsicCfgFile3;
        }else{
            if( $localUTR eq "off" ) {
                assign_ex_cfg("ep.cfg");
            } else {
                assign_ex_cfg("ep_utr.cfg");
            }
        }
        copy($extrinsicCfgFile, "ex1$genesetId.cfg");
        run_augustus_single_core_hints($adjustedHintsFile, $extrinsicCfgFile,
            $localUTR, "Ppri5$genesetId");
        make_gtf("$otherfilesDir/augustus.Ppri5$genesetId.gff");
        if(not($skip_fixing_broken_genes)){
            get_anno_fasta("$otherfilesDir/augustus.Ppri5$genesetId.gtf", "tmp");
            if(-e "$otherfilesDir/bad_genes.lst"){
                fix_ifs_genes("augustus.Ppri5$genesetId", 
                              "$otherfilesDir/augustus.Ppri5$genesetId.gtf", 
                              $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                              $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                              $AUGUSTUS_SCRIPTS_PATH, $adjustedHintsFile, $extrinsicCfgFile);
            }
        }
    }else{
        print LOG "\# " . (localtime) . ": Skip making file "
            . "$otherfilesDir/augustus.Ppri5$genesetId.gff because file is up "
            . "to date.\n" if ($v > 3);
    }

    $adjustedHintsFile = "$hintsfile.E";
    if ( !uptodate( [$hintsfile], [$adjustedHintsFile] ) || $overwrite ) {
        get_rnaseq_hints($hintsfile, $adjustedHintsFile);
    }else{
        print LOG "\# " . (localtime) . ": Skip making adjusted hints file "
            . "$adjustedHintsFile from hintsfile $hintsfile because file is up "
            . "to date.\n" if ($v > 3);
    }
    if ( !uptodate( [$adjustedHintsFile], 
        ["$otherfilesDir/augustus.E$genesetId.gff"] ) || $overwrite ) {
        if (defined ($extrinsicCfgFile2) && $localUTR eq "off") {
            $extrinsicCfgFile = $extrinsicCfgFile2;
        }elsif(defined ($extrinsicCfgFile4) && $localUTR eq "on"){
            $extrinsicCfgFile = $extrinsicCfgFile4;
        }elsif($localUTR eq "off"){
            assign_ex_cfg("rnaseq.cfg");
        }else{
            assign_ex_cfg("rnaseq_utr.cfg");
        }
        copy_ex_cfg($extrinsicCfgFile, "ex2$genesetId.cfg");
        run_augustus_single_core_hints($adjustedHintsFile, $extrinsicCfgFile,
            $localUTR, "E$genesetId");
        make_gtf("$otherfilesDir/augustus.E$genesetId.gff");
        if(not($skip_fixing_broken_genes)){
            get_anno_fasta("$otherfilesDir/augustus.E$genesetId.gtf", "tmp");
            if(-e "$otherfilesDir/bad_genes.lst"){
                fix_ifs_genes("augustus.E$genesetId", 
                              "$otherfilesDir/augustus.E$genesetId.gtf", 
                              $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                              $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                              $AUGUSTUS_SCRIPTS_PATH, $adjustedHintsFile, $extrinsicCfgFile);
            }
        }
    } else {
        print LOG "\# " . (localtime) . ": Skip making file "
            . "$otherfilesDir/augustus.E$genesetId.gff because file is up "
            . "to date.\n" if ($v > 3);
    }
    if( !uptodate(["$otherfilesDir/augustus.Ppri5$genesetId.gtf", 
        "$otherfilesDir/augustus.E$genesetId.gtf"], 
        ["$otherfilesDir/augustus.hints$genesetId.gtf"]) || $overwrite ) {
        joingenes("$otherfilesDir/augustus.Ppri5$genesetId.gtf",
            "$otherfilesDir/augustus.E$genesetId.gtf", $genesetId);
    }else{
        print LOG "\# " . (localtime) . ": Skip running joingenes with input "
            . "files $otherfilesDir/augustus.E$genesetId.gtf and "
            . "$otherfilesDir/augustus.Ppri5$genesetId.gtf to produce "
            . "$otherfilesDir/augustus.hints$genesetId.gtf because file is "
            . "up to date.\n" if ($v > 3);
    }
}

####################### copy_ex_cfg ############################################
# * copy the extrinsic config file to braker working directory
################################################################################

sub copy_ex_cfg {
    my $thisCfg = shift;
    my $target = shift;
    if ( not( -d "$parameterDir/$species/" ) ) {
        mkdir "$parameterDir/$species/";
    }
    $cmdString = "cp $thisCfg $parameterDir/$species/$target";
    print LOG "\# "
        . (localtime)
        . ": copy extrinsic file $thisCfg to working directory\n" if ($v > 2);
    print LOG "$cmdString\n" if ($v > 2);
    system("$cmdString") == 0
        or die("ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nFailed to execute: $cmdString!\n");
}

####################### clean_aug_jobs #########################################
# * clean up AUGUSTUS job files from parallelization
# * if not --cleanup: move job files to a separate folder
# * if --cleanup: delete job files
################################################################################

sub clean_aug_jobs {
    my $hintId = shift;
    opendir( DIR, $otherfilesDir ) or die("ERROR in file " . __FILE__
        . " at line ". __LINE__
        . "\nFailed to open directory $otherfilesDir!\n");
    if( $cleanup ) {
        # deleting files from AUGUSTUS parallelization
        print LOG "\# " . (localtime) . ": deleting files from AUGUSTUS "
            . "parallelization\n" if ($v > 3);

        while ( my $file = readdir(DIR) ) {
            my $searchStr = "aug_".$hintId."_";
            if( $file =~ m/$searchStr/){
                print LOG "rm $otherfilesDir/$file\n" if ($v > 3);
                unlink( "$otherfilesDir/$file" ) or die ("ERROR in file "
                    . __FILE__ ." at line ". __LINE__
                    . "\nFailed to delete file $otherfilesDir/$file!\n");
            }
        }

    } else {
        # moving files for AUGUSTUS prallelization to a separate folder
        print LOG "\# " . (localtime) . ": moving files from AUGUSTUS "
            . "parallelization to directory "
            . "$otherfilesDir/augustus_files_$hintId\n" if ($v > 3);
        if ( !-d "$otherfilesDir/augustus_files_$hintId" ) {
            $prtStr = "\# "
                    . (localtime)
                    . ": creating directory "
                    . "$otherfilesDir/augustus_files_$hintId.\n"
                    . "mkdir $otherfilesDir/augustus_files_$hintId\n";
            $logString .= $prtStr if ( $v > 2 );
            make_path("$otherfilesDir/augustus_files_$hintId") or 
                die("ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to create directory "
                . "$otherfilesDir/augustus_files_$hintId!\n");
        }
        while ( my $file = readdir(DIR) ) {
            my $searchStr1 = "aug_".$hintId."_";
            my $searchStr2 = "aug_".$hintId.".";
            my $searchStr3 = "hintsfile.gff.".$hintId;
            my $searchStr4 = $hintId.".job.lst";
            if( $file =~ m/($searchStr1|$searchStr2|$searchStr3|$searchStr4)/){
                print LOG "mv $otherfilesDir/$file "
                     . "$otherfilesDir/augustus_files_$hintId/$file\n" if ($v > 3);
                move("$otherfilesDir/$file", "$otherfilesDir/augustus_files_$hintId/$file") or
                    die ("ERROR in file "
                    . __FILE__ ." at line ". __LINE__
                    . "\nFailed to move $otherfilesDir/$file "
                    . "to $otherfilesDir/augustus_files_$hintId/$file!\n");
            }
        }
    }
    closedir(DIR) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ . "\nFailed to close directory $otherfilesDir!\n");
}

####################### joingenes ##############################################
# * join two AUGUSTUS prediction sets in gff formats into one
################################################################################

sub joingenes {
    my $file1 = shift;
    my $file2 = shift;
    my $genesetId = shift;
    print LOG "\# " . (localtime) . ": Executing joingenes on files $file1 and "
        . "$file2\n" if ($v > 2);
    # determine which source set of P and E supports more transcripts to decide
    # which gene set is to be prioritized higher (the one with more support)
    # use filter_augustus_gff.pl with --src=(P|E) as tool for counting
    my $string = find(
        "filter_augustus_gff.pl",      $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    # file1 is should have predictions with protein hints -> count src=P
    # file2 has predictions with protein and RNA-Seq hints but RNA-Seq had
    # higher priority when running AUGUSTUS -> count src=E
    $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    my $gff_file1 = $file1;
    $gff_file1 =~ s/\.gtf/\.gff/;
    $perlCmdString .= "perl $string --in=$gff_file1 --src=P > $otherfilesDir/file1_ntx";
    print LOG "# Counting the number of transcripts with support from src=P in file $file1...\n";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    open(NTX1, "<", "$otherfilesDir/file1_ntx") or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to open file $otherfilesDir/file1_ntx for reading!\n");
    my @hn_tx_1;
    while(<NTX1>){
        chomp;
        push(@hn_tx_1, $_);
    }
    my $n_tx_1 = $hn_tx_1[0];
    close(NTX1) or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to close file $otherfilesDir/file1_ntx!\n");
    $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    my $gff_file2 = $file1;
    $gff_file2 =~ s/\.gtf/\.gff/;
    $perlCmdString .= "perl $string --in=$gff_file2 --src=E > $otherfilesDir/file2_ntx";
    print LOG "# Counting the number of transcripts with support from src=E in file $file2...\n";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    open(NTX2, "<", "$otherfilesDir/file2_ntx") or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to open file $otherfilesDir/file2_ntx for reading!\n");
    my @hn_tx_2;
    while(<NTX2>){
        chomp;
        push(@hn_tx_2, $_);
    }
    my $n_tx_2 = $hn_tx_2[0];
    close(NTX2) or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to close file $otherfilesDir/file2_ntx!\n");
    if( $cleanup ) {
        print LOG "rm $otherfilesDir/file1_ntx $otherfilesDir/file2_ntx\n";
        unlink("$otherfilesDir/file1_ntx");
        unlink("$otherfilesDir/file2_ntx");
    }
    print LOG "# File $file1 has $n_tx_1 supported transcripts, $file2 has $n_tx_2 supported transcripts\n";
    # filter only supported transcripts from the file with fewer supported transcripts and build joingenes command
    my $join_basis;
    my $join_on_top;
    if($n_tx_1 < $n_tx_2){
        $join_basis = $file2;
        $join_on_top = $file1."_filtered";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string --in=$file1 --src=P --out=$join_on_top";
        print LOG "# Filtering those genes that have evidence by src=P from $file1...\n";
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
                                            . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    }else {
        $join_basis = $file1;
        $join_on_top = $file2."_filtered";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string --in=$file2 --src=E --out=$join_on_top";
        print LOG "# Filtering those genes that have evidence by src=E from $file2...\n";
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
                                            . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    }
    # join two prediction files (join the less supported set on top of the better supported set)
    my $joingenespath = "$AUGUSTUS_BIN_PATH/joingenes";
    $cmdString = "";
    if($nice){
        $cmdString .= "nice ";
    }
    $cmdString .= "$joingenespath --genesets=$join_basis,$join_on_top --priorities=2,1 "
               .  "--output=$otherfilesDir/join$genesetId.gtf 1> /dev/null 2> "
               .  "$errorfilesDir/joingenes$genesetId.err";
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0 or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");
    # find genes in introns from first gene set
    $string = find(
        "findGenesInIntrons.pl",      $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    $perlCmdString .= "perl $string --in_gff=$join_basis "
                   .  "--jg_gff=$otherfilesDir/join$genesetId.gtf "
                   .  "--out_gff=$otherfilesDir/missed.genes$genesetId"."_1.gtf 1> "
                   .  "/dev/null 2> "
                   .  "$errorfilesDir/findGenesInIntrons$genesetId"."_1.err";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    # find genes in introns from second (filtered) gene set
        $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    $perlCmdString .= "perl $string --in_gff=$join_on_top "
                   .  "--jg_gff=$otherfilesDir/join$genesetId.gtf "
                   .  "--out_gff=$otherfilesDir/missed.genes$genesetId"."_2.gtf 1> "
                   .  "/dev/null 2> "
                   .  "$errorfilesDir/findGenesInIntrons$genesetId"."_2.err";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    # merge missed genes in a nonredundant fashion
    if ( (-e "$otherfilesDir/missed.genes$genesetId"."_1.gtf") && (-e "$otherfilesDir/missed.genes$genesetId"."_2.gtf") ) {
        my %tx_lines;
        my %tx_structures;
        open(MISSED1, "<", "$otherfilesDir/missed.genes$genesetId"."_1.gtf") or die("ERROR in file " . __FILE__
             . " at line ". __LINE__ ."\nFailed to open file $otherfilesDir/missed.genes$genesetId"."_1.gtf for reading!\n");
        #Some modifications here to avoid regex hitting the first field:
        while(my $missed_line = <MISSED1>){
            my @gff_parts = split /\t/, $missed_line;
            # need to rename transcripts because names could be the same for different txs in both files
            my ($tx_id, $g_id);
            for (my $i = 8; $i < scalar(@gff_parts); $i++) {
               $gff_parts[$i] =~ m/(g\d+\.t\d+)/;
               $tx_id = "m1-".$1;
               $gff_parts[$i] =~ m/(g\d+)/;
               $g_id = "m1-".$1;
            }
            #Fix suggested by visoca in issue #118, some of my contigs end in g#
            # and get mangled by this line:
            #$_ =~ s/g\d+/$g_id/g;
            #Somewhat modified visoca's fix, since we're working with GTFs,
            # so the gene_id may not be the last tag.
            #Instead, we apply the regex to all fields after 8:
            for (my $i = 8; $i < scalar(@gff_parts); $i++) {
               $gff_parts[$i] =~ s/g\d+/$g_id/g;
            }
            $missed_line = join("\t", @gff_parts);
            #Continue with the rest of the flow:
            push(@{$tx_lines{$tx_id}}, $missed_line);
            if( ($missed_line =~ m/CDS/) or ($missed_line =~ m/UTR/) ) {
                my @t = split /\t/, $missed_line;
                if(not(defined($tx_structures{$tx_id}))){
                    $tx_structures{$tx_id} = $t[0]."_".$t[3]."_".$t[4]."_".$t[6];
                }else{
                    $tx_structures{$tx_id} .= "_".$t[0]."_".$t[3]."_".$t[4]."_".$t[6];
                }
            }
        }
        close(MISSED1) or die("ERROR in file " . __FILE__
              . " at line ". __LINE__ ."\nFailed to close file $otherfilesDir/missed.genes$genesetId"."_1.gtf!\n");
        open(MISSED2, "<", "$otherfilesDir/missed.genes$genesetId"."_2.gtf") or die("ERROR in file " . __FILE__
             . " at line ". __LINE__ ."\nFailed to open file $otherfilesDir/missed.genes$genesetId"."_2.gtf for reading!\n");
        #Some modifications here to avoid regex hitting the first field:
        while(my $missed_line = <MISSED2>){
            my @gff_parts = split /\t/, $missed_line;
            my $tx_id;
            for (my $i = 8; $i < scalar(@gff_parts); $i++) {
               $gff_parts[$i] =~ m/(g\d+\.t\d+)/;
               $tx_id = $1;
            }
            push(@{$tx_lines{$tx_id}}, $missed_line);
            if( ($missed_line =~ m/CDS/) or ($missed_line =~ m/UTR/) ) {
                my @t = split /\t/, $missed_line;
                if(not(defined($tx_structures{$tx_id}))){
                    $tx_structures{$tx_id} = $t[0]."_".$t[3]."_".$t[4]."_".$t[6];
                }else{
                    $tx_structures{$tx_id} .= "_".$t[0]."_".$t[3]."_".$t[4]."_".$t[6];
                }
            }
        }
        close(MISSED2) or die("ERROR in file " . __FILE__
              . " at line ". __LINE__ ."\nFailed to close file $otherfilesDir/missed.genes$genesetId"."_2.gtf!\n");
        # identify unique transcript structures
        my %tx_to_keep;
        while (my ($key, $value) = each (%tx_structures)) {
            $tx_to_keep{$value} = $key;
        }
        open(MISSED, ">", $otherfilesDir."/missed.genes$genesetId.gtf") or die("ERROR in file " . __FILE__
             . " at line ". __LINE__ ."\nFailed to open file $otherfilesDir./missed.genes$genesetId.gtf for writing!\n");
        while(my ($key, $value) = each(%tx_to_keep)){
            foreach(@{$tx_lines{$value}}){
                print MISSED $_;
            }
        }
        close(MISSED) or die("ERROR in file " . __FILE__
             . " at line ". __LINE__ ."\nFailed to close file $otherfilesDir./missed.genes$genesetId.gtf!\n");
    }elsif(-e  "$otherfilesDir/missed.genes$genesetId"."_1.gtf"){
        move("$otherfilesDir/missed.genes$genesetId"."_1.gtf", "$otherfilesDir/missed.genes$genesetId".".gtf") or die(
            "ERROR in file " . __FILE__
             . " at line ". __LINE__ ."\nFailed to to move file $otherfilesDir/missed.genes$genesetId"."_1.gtf to "
             . "$otherfilesDir/missed.genes$genesetId".".gtf!\n");
    }elsif(-e  "$otherfilesDir/missed.genes$genesetId"."_2.gtf"){
        move("$otherfilesDir/missed.genes$genesetId"."_2.gtf", "$otherfilesDir/missed.genes$genesetId".".gtf") or die(
            "ERROR in file " . __FILE__
             . " at line ". __LINE__ ."\nFailed to to move file $otherfilesDir/missed.genes$genesetId"."_2.gtf to "
             . "$otherfilesDir/missed.genes$genesetId".".gtf!\n");
    }

    if (-e "$otherfilesDir/missed.genes$genesetId.gtf") {
        $cmdString = "cat $otherfilesDir/missed.genes$genesetId.gtf >> "
                   . "$otherfilesDir/join$genesetId.gtf";
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
    }
    $string = find(
        "fix_joingenes_gtf.pl",      $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    $perlCmdString .= "perl $string < $otherfilesDir/join$genesetId.gtf "
                   .  "> $otherfilesDir/augustus.hints$genesetId.gtf";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    get_anno_fasta("$otherfilesDir/augustus.hints$genesetId.gtf", "");
    print LOG "\# " . (localtime) . "rm $otherfilesDir/join$genesetId.gtf\n";
    unlink "$otherfilesDir/join$genesetId.gtf" or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to execute: rm $otherfilesDir/join$genesetId.gtf!\n");
    $cmdString = "rm $otherfilesDir/join$genesetId.gtf";
    print LOG "$cmdString\n" if ($v > 3);
}

####################### get_anno_fasta #########################################
# * extract codingseq and protein sequences from AUGUSTUS output
################################################################################

sub get_anno_fasta {
    my $AUG_pred = shift;
    my $label = shift;
    print LOG "\# "
        . (localtime)
        . ": Making a fasta file with protein sequences of $AUG_pred\n"
        if ($v > 2);
    my $name_base = $AUG_pred;
    $name_base =~ s/[^\.]+$//;
    $name_base =~ s/\.$//;
    my @name_base_path_parts = split(/\//, $name_base);
    my $string = find(
        "getAnnoFastaFromJoingenes.py",      $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    my $errorfile = "$errorfilesDir/getAnnoFastaFromJoingenes.".$name_base_path_parts[scalar(@name_base_path_parts)-1]."_".$label.".stderr";
    my $outfile = "$otherfilesDir/getAnnoFastaFromJoingenes.".$name_base_path_parts[scalar(@name_base_path_parts)-1]."_".$label.".stdout";
    my $pythonCmdString = "";
    if ($nice) {
        $pythonCmdString .= "nice ";
    }
    $pythonCmdString .= "$PYTHON3_PATH/python3 $string ";
    if (not($ttable == 1)){
        $pythonCmdString .= "-t $ttable ";
    }
    $pythonCmdString .= "-g $genome -f $AUG_pred "
                     .  "-o $name_base 1> $outfile 2>$errorfile";

    print LOG "$pythonCmdString\n" if ($v > 3);
    system("$pythonCmdString") == 0
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $pythonCmdString\n");
}

####################### make_gtf ###############################################
# * convert AUGUSTUS output to gtf format
################################################################################

sub make_gtf {
    my $AUG_pred = shift;
    @_ = split( /\//, $AUG_pred );
    my $name_base = substr( $_[-1],    0, -4 );
    my $gtf_file_tmp = substr( $AUG_pred, 0, -4 ) . ".tmp.gtf";
    my $gtf_file  = substr( $AUG_pred, 0, -4 ) . ".gtf";
    if( !uptodate([$AUG_pred], [$gtf_file]) || $overwrite ) {
        print LOG "\# " . (localtime) . ": Making a gtf file from $AUG_pred\n"
            if ($v > 2);
        my $errorfile  = "$errorfilesDir/gtf2gff.$name_base.gtf.stderr";
        my $perlstring = find(
            "gtf2gff.pl",           $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH );
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        my $cmdString .= "cat $AUG_pred | perl -ne 'if(m/\\tAUGUSTUS\\t/) {print \$_;}' | perl $perlstring --printExon --out=$gtf_file_tmp 2>$errorfile";
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line ". __LINE__ ."\nFailed to execute: $cmdString\n");
        open (GTF, "<", $gtf_file_tmp) or die("ERROR in file " . __FILE__
            . " at line ". __LINE__ ."\nCannot open file $gtf_file_tmp\n");
        open (FINALGTF, ">", $gtf_file) or die("ERROR in file " . __FILE__
            . " at line ". __LINE__ ."\nCannot open file $gtf_file\n");
        while(<GTF>){
            if(not($_ =~ m/\tterminal\t/) && not($_ =~ m/\tinternal\t/) && not ($_ =~ m/\tinitial\t/) && not ($_ =~ m/\tsingle\t/)) {
                print FINALGTF $_;
            }
        }
        close (FINALGTF) or die ("ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nCannot close file $gtf_file\n");
        close(GTF) or die("ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nCannot close file $gtf_file_tmp\n");
    }else{
        print LOG "\# " . (localtime) . ": Skip making gtf file from $AUG_pred "
            . "because $gtf_file is up to date.\n" if ($v > 3);
    }
}

####################### evaluate ###############################################
# * evaluate gene predictions (find prediction files, start eval_gene_pred)
################################################################################

sub evaluate {
    my @results;
    my $seqlist = "$otherfilesDir/seqlist";
    print LOG "\# "
        . (localtime)
        . ": Trying to evaluate braker.pl gene prediction files...\n" if ($v > 2);
    if ( -e "$otherfilesDir/augustus.ab_initio.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/augustus.ab_initio.gtf!\n"
            if ($v > 3);
        eval_gene_pred("$otherfilesDir/augustus.ab_initio.gtf");
    }else{
         print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/augustus.ab_initio.gtf!\n"
            if ($v > 3);
    }

    if ( -e "$otherfilesDir/augustus.ab_initio_utr.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/augustus.ab_initio_utr.gtf!\n"
            if ($v > 3);
        eval_gene_pred("$otherfilesDir/augustus.ab_initio_utr.gtf");
    }else{
         print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/augustus.ab_initio_utr.gtf!\n"
            if ($v > 3);
    }

    if ( -e "$otherfilesDir/augustus.hints.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/augustus.hints.gtf!\n"
            if ($v > 3);
        eval_gene_pred("$otherfilesDir/augustus.hints.gtf");
    }else{
        print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/augustus_hints.gtf!\n"
            if ($v > 3);
    }

        if ( -e "$otherfilesDir/augustus.hints_iter1.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/augustus.hints_iter1.gtf!\n"
            if ($v > 3);
        eval_gene_pred("$otherfilesDir/augustus.hints_iter1.gtf");
    }else{
        print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/augustus_hints_iter1.gtf!\n"
            if ($v > 3);
    }

    if ( -e "$otherfilesDir/augustus.hints_utr.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/augustus.hints_utr.gtf!\n"
            if ($v > 3);
        eval_gene_pred("$otherfilesDir/augustus.hints_utr.gtf");
    }else{
        print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/augustus_hints_utr.gtf!\n"
            if ($v > 3);
    }

    if ( -e "$genemarkDir/genemark.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $genemarkDir/genemark.gtf!\n" if ($v > 3);
        eval_gene_pred("$genemarkDir/genemark.gtf");
    }else{
        print LOG "\# "
            . (localtime)
            . ": did not find $genemarkDir/genemark.gtf!\n" if ($v > 3);
    }

    if ( -e "$otherfilesDir/braker.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/braker.gtf!\n" if ($v > 3);
        eval_gene_pred("$otherfilesDir/braker.gtf");
    }else{
        print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/braker.gtf!\n" if ($v > 3);
    }

    if ( -e "$otherfilesDir/braker_iter1.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/braker_iter1.gtf!\n" if ($v > 3);
        eval_gene_pred("$otherfilesDir/braker_iter1.gtf");
    }else{
        print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/braker_iter1.gtf!\n" if ($v > 3);
    }

    if ( -e "$otherfilesDir/braker_utr.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/braker_utr.gtf!\n" if ($v > 3);
        eval_gene_pred("$otherfilesDir/braker_utr.gtf");
    }else{
        print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/braker_utr.gtf!\n" if ($v > 3);
    }

    if ( -e "$otherfilesDir/gthTrainGenes.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/gthTrainGenes.gtf!\n" if ($v > 3);
        eval_gene_pred("$otherfilesDir/gthTrainGenes.gtf");
    }else{
        print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/gthTrainGenes.gtf!\n" if ($v > 3);
    }
    my @accKeys = keys %accuracy;
    if(scalar(@accKeys) > 0){
        print LOG "\# "
        . (localtime)
        . ": was able to run evaluations on ". scalar (@accKeys)
        . "gene sets. Now summarizing "
        . "eval results...\n" if ($v > 3);
        open (ACC, ">", "$otherfilesDir/eval.summary") or die ("ERROR in file "
            . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $otherfilesDir/eval.summary");
        print ACC "Measure";
        foreach(@accKeys){
            chomp;
            print ACC "\t$_";
        }
        print ACC "\n";

        my @gene_sens;
        my @gene_spec;
        my @trans_sens;
        my @trans_spec;
        my @exon_sens;
        my @exon_spec;
        for( my $i = 0; $i < 6; $i ++){
            if( $i == 0 ){ print ACC "Gene_Sensitivity" }
            elsif( $i == 1 ){ print ACC "Gene_Specificity" }
            elsif( $i == 2 ){ print ACC "Transcript_Sensitivity" }
            elsif( $i == 3 ){ print ACC "Transcript_Specificity" }
            elsif( $i == 4 ){ print ACC "Exon_Sensitivity" }
            elsif( $i == 5 ){ print ACC "Exon_Specificity" }
            foreach(@accKeys){
                chomp(${$accuracy{$_}}[$i]);
                print ACC "\t".${$accuracy{$_}}[$i];
                if($i == 0){
                    push(@gene_sens, ${$accuracy{$_}}[$i]);
                }elsif($i == 1){
                    push(@gene_spec, ${$accuracy{$_}}[$i]);
                }elsif($i == 2){
                    push(@trans_sens, ${$accuracy{$_}}[$i]);
                }elsif($i == 3){
                    push(@trans_spec, ${$accuracy{$_}}[$i]);
                }elsif($i == 4){
                    push(@exon_sens, ${$accuracy{$_}}[$i]);
                }elsif($i == 5){
                    push(@exon_spec, ${$accuracy{$_}}[$i]);
                }
            }
            print ACC "\n";
            if( $i == 1 ){
                print ACC "Gene_F1"; 
                if( ($a+$b)  > 0) {
                    my @f1_gene = pairwise { (2*$a*$b)/($a+$b)} @gene_sens, @gene_spec;                        
                    foreach(@f1_gene){
                        print ACC "\t";
                        printf ACC "%.2f", $_;
                    }
                } else {
                    print ACC "\tNA";
                }
                print ACC "\n";
            }elsif( $i == 3 ){
                print ACC "Transcript_F1"; 
                if( ($a+$b)  > 0) {                
                    my @f1_trans = pairwise { (2*$a*$b)/($a+$b)} @trans_sens, @trans_spec;
                    foreach(@f1_trans){
                        print ACC "\t";
                        printf ACC "%.2f", $_;
                    }
                } else {
                    print ACC "\tNA";
                }
                print ACC "\n";
            }elsif( $i == 5 ){
                print ACC "Exon_F1";
                if( ($a+$b)  > 0) {   
                    my @f1_exon = pairwise { (2*$a*$b)/($a+$b)} @exon_sens, @exon_spec;
                    foreach(@f1_exon){
                        print ACC "\t";
                        printf ACC "%.2f", $_;
                    }
                } else {
                    print ACC "\tNA";
                }   
                print ACC "\n";
            }
        }
        close(ACC) or die ("ERROR in file " . __FILE__ . " at line "
            . __LINE__ ."\nCould not close file $otherfilesDir/eval.summary");
    }
    print LOG "\# "
        . (localtime)
        . ": Done with evaluating braker.pl gene prediction files!\n" if ($v > 3);
}

####################### eval_gene_pred #########################################
# * evaluate a particular gene set in gtf format
# * switched to scripts form GaTech written by Alex & Tomas in Februrary 2020
# * their scripts are included in BRAKER repository
################################################################################

sub eval_gene_pred {
    my $gtfFile        = shift;
    my $compute_accuracies = find(
        "compute_accuracies.sh",    $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    print LOG "\# "
        . (localtime)
        . ": Trying to evaluate predictions in file $gtfFile\n" if ($v > 3);
    $cmdString = "$compute_accuracies $annot $annot_pseudo $gtfFile gene trans cds";
    my @res = `$cmdString`; # when using system, it did not print to file
    my @eval_result;
    foreach(@res){
        my @line = split(/\t/);
        push(@eval_result, $line[1]);
    }
    $accuracy{$gtfFile} = \@eval_result;
}

####################### train_utr ##############################################
# * train UTR parameters for AUGUSTUS
################################################################################

sub train_utr {
    print LOG "\# " . (localtime) . ": Training AUGUSTUS UTR parameters\n"
        if ( $v > 2 );
    my $loci = 0;
    my $testSetSize = 0;
    my $onlyTrainSize = 0;
    # copy species parameter files, revert later if UTR model does not improve
    # predictions
    print LOG "\# " . (localtime)
        . ": Create backup of current species parameters:\n" if ( $v > 3 );
    for ( ( "$species" . "_exon_probs.pbl",
            "$species" . "_igenic_probs.pbl",
            "$species" . "_intron_probs.pbl" ) ) {
        print LOG "cp $AUGUSTUS_CONFIG_PATH/species/$species/$_ "
            . "$AUGUSTUS_CONFIG_PATH/species/$species/$_.noUTR\n" if ( $v > 3 );
        copy( "$AUGUSTUS_CONFIG_PATH/species/$species/$_",
              "$AUGUSTUS_CONFIG_PATH/species/$species/$_.noUTR" )
            or die( "ERROR in file " . __FILE__ . " at line " . __LINE__
                . "\nCopy of $AUGUSTUS_CONFIG_PATH/species/$species/$_ to "
                . "$AUGUSTUS_CONFIG_PATH/species/$species/$_.noUTR failed!\n" );
    }
    chdir($otherfilesDir) or die( "ERROR in file " . __FILE__ . " at line "
            . __LINE__
            . "\nCould not change into directory $otherfilesDir!\n" );

    # search all start and stop codons from augustus.gtf and write them
    # to the file stops.and.starts.gff
    my $augustus_file;
    if( defined($AUGUSTUS_hints_preds) ) {
        $augustus_file = $AUGUSTUS_hints_preds;
    }else{
        $augustus_file = "$otherfilesDir/augustus.hints.gtf";
    }

    # compute flanking region size if undefined
    if( not( defined($flanking_DNA) ) ) {
        print LOG "\# " . (localtime)
            . ": WARNING: \$flanking_DNA is undefined, computing value for this variable from "
            . " file $augustus_file. Originally, it was intended that the same value for "
            . "\$flanking_DNA is used in general AUGUSTUS training and UTR training. You can "
            . "define --flanking_DNA=INT as command line parameter when calling BRAKER. You "
            . "find the orignal size of \$flanking_DNA in the braker.log file of the original "
            . "BRAKER run for this species.\n" if ( $v > 2 );
        $flanking_DNA = compute_flanking_region($augustus_file);
    }

    if ( !uptodate( [$augustus_file],
        ["$otherfilesDir/stops.and.starts.gff"] ) ) {

        filter_augustus($augustus_file);
        $augustus_file = "$otherfilesDir/augustus.hints.f.gtf";
        print LOG "\# " . (localtime)
            . ": extracting all stop and start codons from "
            . "$augustus_file to stops.and.starts.gff\n"
            if ( $v > 3 );
        my %nonRedundantCodons;
        my @tmpGffLine;
        open( AUG, "<", "$augustus_file" )
            or die( "ERROR in file " . __FILE__ . " at line " . __LINE__
                . "\nCould not open file "
                . "$augustus_file!\n" );
        # remove transcripts that are redundant by start/stop codon position
        while ( defined( my $i = <AUG> ) ) {
            if ( $i =~ /\t(start_codon|stop_codon)\t/ ) {
                @tmpGffLine = split( /\t/, $i );
                if ( not( defined( $nonRedundantCodons{"$tmpGffLine[0]_$tmpGffLine[3]_$tmpGffLine[4]_$tmpGffLine[6]"} ) ) ) {
                    $nonRedundantCodons{"$tmpGffLine[0]_$tmpGffLine[3]_$tmpGffLine[4]_$tmpGffLine[6]" } = $i;
                }
            }
        }
        close(AUG) or die( "ERROR in file " . __FILE__ . " at line " . __LINE__
            . "\nCould not close file "
            . "$augustus_file!\n" );
        open( CODON, ">", "$otherfilesDir/stops.and.starts.gff" )
            or die( "ERROR in file " . __FILE__ . " at line " . __LINE__
                . "\nCould not open file "
                . "$otherfilesDir/stops.and.starts.gff!\n" );
        foreach my $key ( keys %nonRedundantCodons ) {
            print CODON $nonRedundantCodons{$key};
        }
        close(CODON) or die( "ERROR in file " . __FILE__ . " at line "
            . __LINE__ . "\nCould not close file "
            . "$otherfilesDir/stops.and.starts.gff!\n" );
    }

    if ( !uptodate( ["$hintsfile"], ["$otherfilesDir/rnaseq.utr.hints"] ) ) {
        print LOG "\# " . (localtime)
            . ": Filtering RNA-Seq hints for valid splice site AT-AG, storing "
            . "in $otherfilesDir/rnsaeq.utr.hints\n" if ( $v > 3 );
        #TODO: do not load entire genome in memory, process chromsome-wise!
        my %genome_hash;
        my $hash_key;
        open( FASTA, "<", $genome ) or die( "ERROR in file " . __FILE__
            . " at line " . __LINE__ . "\nCould not open file $genome!\n" );
        LINE: while ( my $line = <FASTA> ) {
            next LINE if $line =~ m/^#/;
            if ( $line =~ /^>/ ) {
                chomp($line);
                $hash_key = substr( $line, 1, length($line) - 1 );
            } else {
                $line =~ s/[\x0A\x0D]+//g;
                $line =~ s/(\s+)(\n)(\r)//g;
                $line = uc($line);
                $genome_hash{$hash_key} .= $line;
            }
        }
        close(FASTA) or die( "ERROR in file " . __FILE__ . " at line "
                . __LINE__ . "\nCould not close file $genome!\n" );
        open( HINTS, "<", $hintsfile ) or die( "ERROR in file " . __FILE__
            . " at line " . __LINE__ . "\nCould not open file $hintsfile!\n" );
        my @gff;
        my ( $siteA, $siteB, $given, $lastCol );
        open( UTRHINTS, ">", "$otherfilesDir/rnaseq.utr.hints" )
            or die( "ERROR in file " . __FILE__ . " at line " . __LINE__
            . "\nCould not open file rnaseq.utr.hints!\n" );
        while ( my $line = <HINTS> ) {
            @gff = split( /\t/, $line );
            if ( ( $gff[1] eq "b2h" ) && ( $gff[2] eq "intron" ) ){
                $siteA = substr( $genome_hash{ $gff[0] }, ( $gff[3] - 1 ), 2 );
                $siteB = substr( $genome_hash{ $gff[0] }, ( $gff[4] - 2 ), 2 );
                $given = $siteA . $siteB;
                foreach(@splice){
                    if ( $gff[8] =~ m/mult=(\d+)/ ) {
                        $lastCol = "mult=".$1."_$_\n";
                    }else {
                        $lastCol = "mult=1_$_\n";
                    }
                    if ( uc($given) =~ m/$_/ ) {
                        for(my $i = 0; $i < 8; $i++){
                            if($i != 6 ) {
                                print UTRHINTS $gff[$i] . "\t";
                            }else{
                                print UTRHINTS "+\t";
                            }
                        }
                        print UTRHINTS $lastCol;
                    } else {
                        $given = reverse $given;
                        $given =~ tr/ACGTacgt/TGCAtgca/;
                        if ( uc($given) =~ m/$_/ ) {
                            for(my $i = 0; $i < 8; $i++){
                                if($i != 6 ) {
                                    print UTRHINTS $gff[$i] . "\t";
                                }else{
                                    print UTRHINTS "-\t";
                                }
                            }
                            print UTRHINTS $lastCol;
                        }
                    }
                }
            }
        }
        close(UTRHINTS) or die( "ERROR in file " . __FILE__ . " at line "
            . __LINE__ . "\nCould not close file "
            . "$otherfilesDir/rnaseq.utr.hints!\n" );
        close(HINTS) or die( "ERROR in file " . __FILE__ . " at line "
            . __LINE__ . "\nCould not close file $hintsfile!\n" );
    }

    # create wiggle file from bam files
    if(!@stranded){
        if ( !uptodate( ["$hintsfile"], ["$otherfilesDir/merged.wig"] ) ) {
            bam2wig()
        }
    }else{
        bam2stranded_wig();
    }

    # call utrrnaseq; if no stranded data is supplied, once, if stranded
    # or mixed data is provided, for plus and minus strand; unstranded data
    # will be ignored in this case:
    if(!@stranded){
        if ( !uptodate( ["$hintsfile"], ["$otherfilesDir/utrs.gff"] ) ) {
            print LOG "\# " . (localtime) . ": Creating $otherfilesDir/utrs.gff\n"
                if ( $v > 3 );
            if(!@stranded){
                $cmdString = "";
                if ($nice) {
                    $cmdString .= "nice ";
                }
                $cmdString .= "$rnaseq2utr --in-scaffold-file $genome "
                           .  "-C $otherfilesDir/stops.and.starts.gff "
                           .  "-I $otherfilesDir/rnaseq.utr.hints "
                           .  "-W $otherfilesDir/merged.wig "
                           .  "-o $otherfilesDir/utrs.gff ";
                if( $rnaseq2utr_args ) {
                    $cmdString .= "$rnaseq2utr_args ";
                }
                $cmdString .=  "1> $otherfilesDir/rnaseq2utr.stdout "
                            .  "2> $errorfilesDir/rnaseq2utr.err";
                print LOG "\n$cmdString\n" if ( $v > 3 );
                system("$cmdString") == 0 or die( "ERROR in file " . __FILE__
                    . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n" );
                # utrrnaseq has a bug that outputs "fake copies" of UTR lines where the
                # fourth column contains smaller coordinates thant he third gff column
                # have to fix this, for now, remove those lines in braker
                # Katharina fixed the utrrnaseq issues on August 13th 2018, could
                # remove the UTRFIX code from braker, now.
                print LOG "\# " . (localtime) . ": fixing utrrnaseq output\n";
                open (UTR, "<", "$otherfilesDir/utrs.gff" ) or die( "ERROR in file "
                    . __FILE__ . " at line " . __LINE__
                    . "\nCan not open file $otherfilesDir/utrs.gff!\n" );
                open (UTRFIX, ">", "$otherfilesDir/utrs.f.gff") or die( "ERROR in file "
                    . __FILE__ . " at line " . __LINE__
                    . "\nCan not open file $otherfilesDir/utrs.f.gff!\n" );
                while(<UTR>) {
                    my @l = split(/\t/);
                    if($l[4] > $l[3]){
                        print UTRFIX $_;
                    }
                }
                close(UTRFIX) or die( "ERROR in file " . __FILE__ . " at line " . __LINE__
                    . "\nCould not close file $otherfilesDir/utrs.f.gff!\n" );
                close(UTR) or die( "ERROR in file " . __FILE__ . " at line " . __LINE__
                    . "\nCould not close file $otherfilesDir/utrs.gff!\n" );
                $cmdString = "mv $otherfilesDir/utrs.f.gff $otherfilesDir/utrs.gff";
                print LOG "\n$cmdString\n" if ($v > 3);
                system("$cmdString") == 0 or die( "ERROR in file " . __FILE__
                    . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n" );
            }
        }
    }else{
        my @names;
        my $utrs_file = "$otherfilesDir/utrs.gff";
        if(-e "$otherfilesDir/rnaseq_plus.bam"){
            push(@names, "plus");
        }
        if(-e "$otherfilesDir/rnaseq_minus.bam"){
            push(@names, "minus");
        }
        foreach(@names){
            my $this_strand;
            if($_ eq "plus"){
                $this_strand = "+";
            }else{
                $this_strand = "-";
            }
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "$rnaseq2utr --in-scaffold-file $genome "
                       .  "-C $otherfilesDir/stops.and.starts.gff "
                       .  "-I $otherfilesDir/rnaseq.utr.hints "
                       .  "-W $otherfilesDir/rnaseq_".$_.".wig "
                       .  "-o $otherfilesDir/utrs_".$_.".gff ";
            if( $rnaseq2utr_args ) {
                $cmdString .= "$rnaseq2utr_args ";
            }
            $cmdString .=  "1> $otherfilesDir/rnaseq2utr_".$_.".stdout "
                        .  "2> $errorfilesDir/rnaseq2utr_".$_.".err";
            print LOG "\n$cmdString\n" if ( $v > 3 );
            system("$cmdString") == 0 or die( "ERROR in file " . __FILE__
                . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n" );
            # filter utrs from the current strand!
            open(MERGEDUTRS, ">", $utrs_file) or die ("ERROR in file " 
                . __FILE__ . " at line " . __LINE__ . "\nFailed to open file "
                . $utrs_file . " for writing!\n");
            open(ONESTRANDUTRS, "<", "$otherfilesDir/utrs_".$_.".gff") or
                die("ERROR in file " . __FILE__ . " at line " . __LINE__ 
                . "\nFailed to open file " . "$otherfilesDir/utrs_".$_.".gff" 
                . " for reading!\n");
            while(<ONESTRANDUTRS>){
                my @line = split(/\t/);
                if( ($line[3] < $line[4]) && ($line[6] eq $this_strand) ) {
                    print MERGEDUTRS $_;
                }
            }
            close(ONESTRANDUTRS) or die ("ERROR in file " 
                . __FILE__ . " at line " . __LINE__ . "\nFailed to close file "
                . "$otherfilesDir/utrs_".$_.".gff" . "!\n");
            close(MERGEDUTRS) or die ("ERROR in file " 
                . __FILE__ . " at line " . __LINE__ . "\nFailed to close file "
                . $utrs_file . "!\n");
        }
    }

    # create genbank file with genes that have two utrs
    if (!uptodate( [ "$otherfilesDir/utrs.gff",    $augustus_file ],
            [ "$otherfilesDir/bothutr.lst", "$otherfilesDir/bothutr.test.gb" ] ) ) {
        print LOG "\# " . (localtime) . ": Creating gb file for UTR training\n"
            if ( $v > 3 );

        # extract subset of genes, where we have both UTRs
        open( UTR, "<", "$otherfilesDir/utrs.gff" ) or die( "ERROR in file "
            . __FILE__ . " at line " . __LINE__
            . "\nCan not open file $otherfilesDir/utrs.gff!\n" );
        my %both;
        while (<UTR>) {
            my @t = split(/\t/);
            $t[8]=~m/transcript_id \"(\S+)\"/;
            my $txid = $1;
            if($t[2] =~ m/UTR/){
                $both{$txid}{$t[2]} = $_;
            }
        }
        close(UTR) or die( "ERROR in file " . __FILE__ . " at line " . __LINE__
            . "\nCould not close file $otherfilesDir/utrs.gff!\n" );

        open( BOTH, ">", "$otherfilesDir/bothutr.lst" ) or die( "ERROR in file "
            . __FILE__ . " at line " . __LINE__
            . "\nCan not open file $otherfilesDir/bothutr.lst!\n" );
        foreach(keys %both){
            if(defined($both{$_}{"3'-UTR"}) && defined($both{$_}{"5'-UTR"})){
                print BOTH $_."\n";
            }
        }
        close(BOTH) or die( "ERROR in file " . __FILE__ . " at line "
            . __LINE__
            . "\nCould not close file $otherfilesDir/bothutr.lst!\n" );
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString .= "cat $otherfilesDir/utrs.gff "
                   .  "$augustus_file | "
                   .  "grep -P \"(CDS|5'-UTR|3'-UTR)\" | "
                   .  "sort -n -k 4,4 | "
                   .  "sort -s -k 10,10 | sort -s -k 1,1 >"
                   .  "> $otherfilesDir/genes.gtf "
                   .  "2> $errorfilesDir/cat_utrs_augustus_noUtrs.err";
        print LOG "\n$cmdString\n" if ( $v > 3 );
        system($cmdString) == 0 or die( "ERROR in file " . __FILE__
            . " at line " . __LINE__
            . "\nFailed not execute $cmdString!\n" );

        $string = find(
            "gff2gbSmallDNA.pl",    $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string $otherfilesDir/genes.gtf $genome "
                       .  "$flanking_DNA $otherfilesDir/utr.gb "
                       .  "--good=$otherfilesDir/bothutr.lst "
                       .  "1> $otherfilesDir/gff2gbSmallDNA.utr.stdout "
                       . "2> $errorfilesDir/gff2gbSmallDNA.utr.stderr";
        print LOG "\n$perlCmdString\n" if ( $v > 3 );
        system("$perlCmdString") == 0 or die( "ERROR in file " . __FILE__
            . " at line " . __LINE__
            . "\nFailed to execute: $perlCmdString!\n" );

        # assign LOCI locations to txIDs
        open (TRAINUTRGB1, "<", "$otherfilesDir/utr.gb") or die(
            "ERROR in file " . __FILE__ . " at line " . __LINE__
            . "\nCould not open file $otherfilesDir/utr.gb!\n" );

        my %txInUtrGb1;
        my $txLocus;;
        while( <TRAINUTRGB1> ) {
            if ( $_ =~ m/LOCUS\s+(\S+)\s/ ) {
                $txLocus = $1;
            }elsif ( $_ =~ m/\/gene=\"(\S+)\"/ ) {
                $txInUtrGb1{$1} = $txLocus;
            }
        }
        close (TRAINUTRGB1) or die(
            "ERROR in file " . __FILE__ . " at line " . __LINE__
            . "\nCould not close file $otherfilesDir/utr.gb!\n" );

        # find those genes in gtf that ended up in gb file
        open(GENES, "<", "$otherfilesDir/genes.gtf") or die( "ERROR in file "
            . __FILE__ . " at line " . __LINE__
            . "\nCould not open file $otherfilesDir/genes.lst!\n" );
        open(GENESINGB, ">", "$otherfilesDir/genes_in_gb.gtf") or die(
            "ERROR in file " . __FILE__ . " at line " . __LINE__
            . "\nCould not open file $otherfilesDir/genes_in_gb.gtf!\n" );
        while(<GENES>){
            if($_=~m/transcript_id \"(\S+)\"/){
                if(defined($txInUtrGb1{$1})){
                    print GENESINGB $_;
                }
            }
        }
        close(GENESINGB) or die( "ERROR in file "
            . __FILE__ . " at line " . __LINE__
            . "\nCould not close file $otherfilesDir/genes_in_gb.gtf!\n" );
        close(GENES) or die( "ERROR in file "
            . __FILE__ . " at line " . __LINE__
            . "\nCould not close file $otherfilesDir/genes.lst!\n" );

        # convert those training genes to protein fasta file
        gtf2fasta ($genome, "$otherfilesDir/genes_in_gb.gtf",
            "$otherfilesDir/utr_genes_in_gb.fa", $ttable);

        # blast good training genes to exclude redundant sequences
        $string = find(
            "aa2nonred.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        if(defined($DIAMOND_PATH) and not(defined($blast_path))){
            $perlCmdString .= "perl $string $otherfilesDir/utr_genes_in_gb.fa "
                           .  "$otherfilesDir/utr_genes_in_gb.nr.fa "
                           .  "--DIAMOND_PATH=$DIAMOND_PATH --cores=$CPU "
                           .  "--diamond 1> $otherfilesDir/utr.aa2nonred.stdout "
                           .  "2> $errorfilesDir/utr.aa2nonred.stderr";
            print CITE $pubs{'diamond'}; $pubs{'diamond'} = "";
        }else{
            $perlCmdString .= "perl $string $otherfilesDir/utr_genes_in_gb.fa "
                           .  "$otherfilesDir/utr_genes_in_gb.nr.fa "
                           .  "--BLAST_PATH=$BLAST_PATH --cores=$CPU 1> "
                           .  "$otherfilesDir/utr.aa2nonred.stdout "
                           .  "2> $errorfilesDir/utr.aa2nonred.stderr";
            print CITE $pubs{'blast1'}; $pubs{'blast1'} = "";
            print CITE $pubs{'blast2'}; $pubs{'blast2'} = "";
        }
        print LOG "\# "
            . (localtime)
            . ": DIAMOND/BLAST training gene structures (with UTRs) against "
            . "themselves:\n" if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or die( "ERROR in file " . __FILE__
            . " at line " . __LINE__
            . "\nFailed to execute: $perlCmdString!\n" );

        # parse output of blast
        my %nonRed;
        open (BLASTOUT, "<", "$otherfilesDir/utr_genes_in_gb.nr.fa") or
             die( "ERROR in file "
            . __FILE__ . " at line " . __LINE__
            . "\nCould not open file $otherfilesDir/utr_genes_in_gb.nr.fa!\n" );
        while ( <BLASTOUT> ) {
            chomp;
            if($_ =~ m/^\>(\S+)/){
                $nonRed{$1} = 1;
            }
        }
        close (BLASTOUT) or  die( "ERROR in file "
            . __FILE__ . " at line " . __LINE__
            . "\nCould not close file $otherfilesDir/utr_genes_in_gb.nr.fa!\n" );

        open ( NONREDLOCI, ">", "$otherfilesDir/utr.nonred.loci.lst") or
            die( "ERROR in file "
            . __FILE__ . " at line " . __LINE__
            . "\nCould not open file $otherfilesDir/utr.nonred.loci.lst!\n" );
        foreach ( keys %nonRed ) {
            print NONREDLOCI $txInUtrGb1{$_}."\n";
        }
        close (NONREDLOCI) or  die( "ERROR in file "
            . __FILE__ . " at line " . __LINE__
            . "\nCould not close file $otherfilesDir/utr.nonred.loci.lst!\n" );

        # filter utr.gb file for nonredundant loci
        $string = find(
            "filterGenesIn.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string $otherfilesDir/utr.nonred.loci.lst "
                       .  "$otherfilesDir/utr.gb 1> $otherfilesDir/utr.nr.gb "
                       .  "2> $errorfilesDir/utr.filterGenesIn.stderr";
        print LOG "\# " . (localtime)
            . ": Filtering nonredundant loci into $otherfilesDir/utr.nr.gb:\n"
            if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or die( "ERROR in file " . __FILE__
            . " at line " . __LINE__
            . "\nFailed not execute $perlCmdString!\n" );

        # count how many genes are still in utr.nr.gb
        if($v > 3) {
            open (TRAINUTRGB2, "<", "$otherfilesDir/utr.nr.gb") or
                die( "ERROR in file " . __FILE__ . " at line " . __LINE__
                . "\nCould not open file $otherfilesDir/utr.nr.gb!\n" );
            my $nLociUtrGb2 = 0;
            while ( <TRAINUTRGB2> ) {
                if($_ =~ m/LOCUS/) {
                    $nLociUtrGb2++;
                }
            }
            close (TRAINUTRGB2) or  die( "ERROR in file " . __FILE__
                . " at line " . __LINE__
                . "\nCould not close file $otherfilesDir/utr.nr.gb!\n" );
            print LOG "\# "
                    . (localtime)
                    . ": $otherfilesDir/utr.nr.gb file contains $nLociUtrGb2 genes.\n";
        }

        # move nonredundant file utr.nr.gb to utr.gb
        $cmdString = "mv $otherfilesDir/utr.nr.gb $otherfilesDir/utr.gb";
        print LOG  "\# " . (localtime) . ": Moving utr.nr.gb to utr.gb file:\n"
            if($v>3);
        print LOG $cmdString."\n";
        system("$cmdString") == 0 or die( "ERROR in file " . __FILE__
            . " at line " . __LINE__
            . "\nFailed to execute: $cmdString!\n" );

        # create an utr.onlytrain.gb if more than 200 UTR training genes
        open(UTRGB, "<", "$otherfilesDir/utr.gb") or die( "ERROR in file "
            . __FILE__ . " at line " . __LINE__
            . "\nCould not open file $otherfilesDir/utr.gb!\n" );
        while(<UTRGB>){
            if($_ =~ m/LOCUS/){
                $loci++
            }
        }
        close(UTRGB) or die( "ERROR in file "
            . __FILE__ . " at line " . __LINE__
            . "\nCould not close file $otherfilesDir/utr.gb!\n" );
        if($loci < 50){
            die("ERROR in file " . __FILE__ . " at line " . __LINE__
            . "\nNumber of UTR training loci is smaller than 50, aborting "
            . "UTR training! If this is the only error message, the "
            . "AUGUSTUS parameters for your species were optimized ok, "
            . "but you are lacking UTR parameters. Do not attempt to "
            . "predict genes with UTRs for this species using the current "
            . "parameter set!\n");
        }elsif( ($loci >= 50) && ($loci <= 1000) ){
            $testSetSize = floor($loci * 0.2);
            if(($loci - $testSetSize) > 200){
                $onlyTrainSize = 200;
            }
        }elsif($loci > 1000){
            $testSetSize = 200;
            $onlyTrainSize = 200;
        }

        # create hold out test set
        $string = find(
            "randomSplit.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        print LOG "Found script $string.\n" if ( $v > 3 );
        $perlCmdString = "perl $string $otherfilesDir/utr.gb $testSetSize "
                       . "1> $otherfilesDir/randomSplit_utr1.log "
                       . "2> $errorfilesDir/randomSplit_utr1.err";
        print LOG "\n$perlCmdString\n" if ( $v > 3 );
        system("$perlCmdString") == 0 or die( "ERROR in file " . __FILE__
            . " at line " . __LINE__
            . "\nFailed to execute: $perlCmdString!\n" );

        # create onlytrain if applicable
        if($onlyTrainSize > 0){
             $string = find(
                "randomSplit.pl",       $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
                );
            print LOG "Found script $string.\n" if ( $v > 3 );
            $perlCmdString = "perl $string $otherfilesDir/utr.gb.train "
                           . "$onlyTrainSize "
                           . "1> $otherfilesDir/randomSplit_utr2.log "
                           . "2> $errorfilesDir/randomSplit_utr2.err";
            print LOG "\n$perlCmdString\n" if ( $v > 3 );
            system("$perlCmdString") == 0 or die( "ERROR in file " . __FILE__
                . " at line " . __LINE__
                . "\nFailed to execute: $perlCmdString!\n" );
        }

        # run AUGUSTUS on UTR test set before UTR training
        if( !uptodate( ["$otherfilesDir/utr.gb.test"],
            ["$otherfilesDir/fourthtest.out"] ) || $overwrite ) {
            $augpath = "$AUGUSTUS_BIN_PATH/augustus";
            $errorfile  = "$errorfilesDir/fourthtest.stderr";
                $stdoutfile = "$otherfilesDir/fourthtest.stdout";
                $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/utr.gb.test >$stdoutfile 2>$errorfile";
            print LOG "\# "
                . (localtime)
                . ": Fourth AUGUSTUS accuracy test (no UTR parameters on UTR test set)\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nFailed to execute: $cmdString\n");
            $target_4 = accuracy_calculator($stdoutfile);
            print LOG "\# ". (localtime) . ": The accuracy before UTR training "
                . "training is $target_4\n" if ($v > 3);
        }

        # changing UTR parameters in species config file to "on"
        print LOG "\# "
            . (localtime)
            . ": Setting value of \"UTR\" in "
            . "$AUGUSTUS_CONFIG_PATH/species/$species/$species\_parameters.cfg "
            . "to \"true\"\n"
            if ( $v > 3 );
        setParInConfig(
            $AUGUSTUS_CONFIG_PATH
            . "/species/$species/$species\_parameters.cfg",
            "UTR", "on"
        );
        setParInConfig(
            $AUGUSTUS_CONFIG_PATH
            . "/species/$species/$species\_parameters.cfg",
            "print_utr", "on"
        );
    }


    if ( !uptodate( [ "utr.gb"], ["optimize.utr.out"] ) ) {

        # prepare metaparameter file
        my $metaUtrName = $species . "_metapars.utr.cfg";
        if (not( -e $AUGUSTUS_CONFIG_PATH . "/species/$species/$metaUtrName" )
            )
        {
            # copy from generic as template
            $cmdString = "cp $AUGUSTUS_CONFIG_PATH"
                       . "/species/generic/generic_metapars.utr.cfg $AUGUSTUS_CONFIG_PATH"
                       . "/species/$species/$metaUtrName";
            print LOG "Copying utr metaparameter template file:\n$cmdString\n"
                if ( $v > 3 );
            system("$cmdString") == 0 or die( "ERROR in file " . __FILE__
                . " at line " . __LINE__
                . "\nFailed to execute: $cmdString!\n" );
        }
        $string = find(
            "optimize_augustus.pl", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        print LOG "Found script $string.\n" if ( $v > 3 );
        if($onlyTrainSize == 0){
            $perlCmdString = "perl $string --rounds=$rounds --species=$species "
                           . "--trainOnlyUtr=1 "
                           . "--metapars=$AUGUSTUS_CONFIG_PATH"
                           . "/species/$species/$metaUtrName --cpus=$CPU "
                           . "$otherfilesDir/utr.gb.train "
                           . "--UTR=on "
                           . "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                           . "> $otherfilesDir/optimize.utr.out";
        }else{
            $perlCmdString = "perl $string --rounds=$rounds --species=$species "
                           . "--trainOnlyUtr=1  "
                           . "--onlytrain=$otherfilesDir/utr.gb.train.train "
                           . "--metapars=$AUGUSTUS_CONFIG_PATH"
                           . "/species/$species/$metaUtrName --cpus=$CPU "
                           . "$otherfilesDir/utr.gb.train.test "
                           . "--UTR=on "
                           . "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                           . "> $otherfilesDir/optimize.utr.stdout "
                           . "2> $errorfilesDir/optimize.utr.err"
        }
        print LOG "Now optimizing meta parameters of AUGUSTUS for the UTR "
            . "model:\n" if ( $v > 3 );
        print LOG "Running \"$perlCmdString\"..." if ( $v > 3 );
        system("$perlCmdString") == 0 or die( "ERROR in file " . __FILE__
            . " at line " . __LINE__
            . "\nFailed to execute: $perlCmdString!\n" );

        # run AUGUSTUS on UTR test set after UTR training
        if( !uptodate( ["$otherfilesDir/utr.gb.test"],
            ["$otherfilesDir/fifthtest.out"] ) || $overwrite ) {
            # decrease patternweight parameters independent of optimize_result
            # because the aim is to predict coding sequences, correctly, merely
            # incorporate ep hints into UTRs where necessary
            #print LOG "\# " . (localtime) . ": Decreasing utr5patternweight "
            #    . "and utr3patternweight to 0.2 in parameters.cfg file "
            #    . "to give priority to correct CDS prediction.\n" if($v > 3);
            #setParInConfig(
            #    $AUGUSTUS_CONFIG_PATH
            #    . "/species/$species/$species\_parameters.cfg",
            #    "/UtrModel/utr5patternweight", "0.2"
            #);
            #setParInConfig(
            #    $AUGUSTUS_CONFIG_PATH
            #    . "/species/$species/$species\_parameters.cfg",
            #    "/UtrModel/utr3patternweight", "0.2"
            $augpath = "$AUGUSTUS_BIN_PATH/augustus";
            $errorfile  = "$errorfilesDir/fifthtest.stderr";
                $stdoutfile = "$otherfilesDir/fifthtest.stdout";
                $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "$augpath --species=$species "
                       .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                       .  "$otherfilesDir/utr.gb.test >$stdoutfile "
                       .  "2>$errorfile";
            print LOG "\# "
                . (localtime)
                . ": Fifth AUGUSTUS accuracy test (with UTR parameters on UTR "
                . "test set)\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nFailed to execute: $cmdString\n");
            $target_5 = accuracy_calculator($stdoutfile);
            print LOG "\# ". (localtime) . ": The accuracy after UTR training "
                . "training is $target_5\n" if ($v > 3);

            if($target_4 > $target_5){
                print LOG "#*********\n"
                     . "# WARNING: UTR training "
                     . "decreased AUGUSTUS ab initio accuracy!\n"
                     . "#*********\n" if ($v > 3);
            }
        }
    }
    else {
        print "Skipping UTR parameter optimization. Already up to date.\n";
    }
}

####################### bam2wig ################################################
# convert merged and sorted bam files to wig file (unstranded data)
################################################################################

sub bam2wig {
    print LOG "\# " . (localtime)
        . ": Converting bam files to wiggle file merged.wig\n" if ( $v > 3 );
    if ( scalar(@bam) > 1 ) {
        print LOG "\# " . (localtime)
            . ": For conversion, merge multiple bam files\n" if ( $v > 3 );
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString .= "$BAMTOOLS_BIN_PATH/bamtools merge ";
        foreach (@bam) {
            chomp;
            $cmdString .= "-in $_ ";
        }
        $cmdString .= "-out $otherfilesDir/merged.bam "
                   .  "1> $otherfilesDir/bam.merge.log "
                   .  "2> $errorfilesDir/bam.merge.err";
        print LOG "\n$cmdString\n" if ( $v > 3 );
        system("$cmdString") == 0 or die( "ERROR in file " . __FILE__
                . " at line " . __LINE__
                . "\nFailed to execute: $cmdString!\n" );
    } else {
        print LOG "\# " . (localtime) . ":  For conversion, creating "
            . "softlink to bam file $bam[0]...\n" if ( $v > 3 );
        $cmdString = "ln -s $bam[0] $otherfilesDir/merged.bam";
        print LOG "$cmdString\n" if ( $v > 3 );
        system($cmdString) == 0 or die( "ERROR in file " . __FILE__
            . " at line " . __LINE__
            . "\nFailed to execute: $cmdString!\n" );
    }
    print LOG "\# " . (localtime) . ": sorting bam file...\n" if ($v > 3);
    $cmdString = "";
    if ($nice) {
        $cmdString .= "nice ";
    }
    # The following command is for current samtools versions:
    $cmdString .= "$SAMTOOLS_PATH/samtools sort -\@ "
               .($CPU-1) . " -o $otherfilesDir/merged.s.bam "
               .  "$otherfilesDir/merged.bam "
               .  "1> $otherfilesDir/samtools_sort_before_wig.stdout "
               .  "2> $errorfilesDir/samtools_sort_before_wig.stderr";
    # If you happen to use an older samtools version, adapt the line above to
    # look as follows:
    # $cmdString .= "$SAMTOOLS_PATH/samtools sort -\@ " .($CPU-1) 
    #    . " $otherfilesDir/merged.bam " . "$otherfilesDir/merged.s " 
    #    . "1> $otherfilesDir/samtools_sort_before_wig.stdout " 
    #    . "2> $errorfilesDir/samtools_sort_before_wig.stderr";
    print LOG "\n$cmdString\n" if ($v > 3);
    system("$cmdString") == 0 or die("ERROR in file " . __FILE__
        . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n");
    print LOG "\# " . (localtime) . ": Creating wiggle file...\n"
        if ( $v > 3 );
    my $string = find(
        "bamToWig.py",      $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    my $pythonCmdString = "";
    if ($nice) {
        $pythonCmdString .= "nice ";
    }
    $pythonCmdString .= "$PYTHON3_PATH/python3 $string -b "
                     .  "$otherfilesDir/merged.s.bam -g $genome "
                     .  "-o $otherfilesDir/merged.wig "
                     .  "2> $errorfilesDir/bamToWig.err";
    print LOG "$pythonCmdString\n" if ($v > 3);
    system("$pythonCmdString") == 0
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $pythonCmdString\n");
}

####################### bam2stranded_wig #######################################
# convert strand separated bam files to  two separate wig files
################################################################################

sub bam2stranded_wig{
    print LOG "\# " . (localtime)
        . ": Converting strand separated bam files to individual wiggle files\n" 
        if ( $v > 3 );
    # determine how many "levels of strandedness" were supplied 
    # (can be +, -, .)
    my $bam_plus = "$otherfilesDir/rnaseq_plus.bam";
    my @plus_index;
    my $bam_minus = "$otherfilesDir/rnaseq_minus.bam";
    my @minus_index;
    my $bam_unstranded = "$otherfilesDir/rnaseq_unstranded.bam";
    my @unstranded_index;
    for(my $i=0; $i < scalar(@stranded); $i++){
        if($stranded[$i] eq "+"){
            push(@plus_index, $i);
        }elsif($stranded[$i] eq "-"){
            push(@minus_index, $i);
        }elsif($stranded[$i] eq "."){
            push(@unstranded_index, $i);
        }else{
            print LOG "\# " . (localtime)
                . " ERROR: argument ". $stranded[$i] ." has been supplied as level of "
                . "strandedness. Allowed are \"+\", \"-\", \".\".";
            print STDERR   "\# " . (localtime)
                . " ERROR: argument ". $stranded[$i] ." has been supplied as level of "
                . "strandedness. Allowed are \"+\", \"-\", \".\".";
            exit(1);
        }
    }
    # merging and sorting plus stranded bam files
    if(scalar(@plus_index) > 1){
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString .= "$BAMTOOLS_BIN_PATH/bamtools merge ";
        foreach (my $i = 0; $i < scalar(@plus_index); $i++) {
            chomp;
            $cmdString .= "-in $bam[$plus_index[$i]] ";
        }
        $cmdString .= "-out $bam_plus "
                   .  "1> $otherfilesDir/bam_plus.merge.log "
                   .  "2> $errorfilesDir/bam_plus.merge.err";
        print LOG "\n$cmdString\n" if ( $v > 3 );
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n");
    }elsif(scalar(@plus_index) == 1){
        $cmdString = "ln -s $bam[$plus_index[0]] $bam_plus";
        print LOG "\n$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n");
    }
    if(scalar(@plus_index > 0)){
        print LOG "\# " . (localtime) . ": sorting bam file $bam_plus...\n" 
            if ($v > 3);
        # create filename for sorted bam file
        my @bam_plus_path = split(/\//, $bam_plus);
        my $thisSortedBamFile = "$otherfilesDir/".$bam_plus_path[scalar(@bam_plus_path)-1];
        $thisSortedBamFile =~ s/\.bam/\.s\.bam/;
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString .= "$SAMTOOLS_PATH/samtools sort -\@ "
               .($CPU-1) . " -o $thisSortedBamFile "
               .  "$bam_plus "
               .  "1> $otherfilesDir/samtools_sort_plus_bam.stdout "
               .  "2> $errorfilesDir/samtools_sort_plus_bam.stderr";
        print LOG "\n$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n");
    }
    # merging and sorting minus stranded bam files
    if(scalar(@minus_index) > 1){
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString .= "$BAMTOOLS_BIN_PATH/bamtools merge ";
        foreach (my $i = 0; $i < scalar(@minus_index); $i++) {
            chomp;
            $cmdString .= "-in $bam[$minus_index[$i]] ";
        }
        $cmdString .= "-out $bam_minus "
                   .  "1> $otherfilesDir/bam_minus.merge.log "
                   .  "2> $errorfilesDir/bam_minus.merge.err";
        print LOG "\n$cmdString\n" if ( $v > 3 );
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n");
    }elsif(scalar(@minus_index) == 1){
        $cmdString = "ln -s $bam[$minus_index[0]] $bam_minus";
        print LOG "\n$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n");
    }
    if(scalar(@minus_index > 0)){
        print LOG "\# " . (localtime) . ": sorting bam file $bam_minus...\n" 
            if ($v > 3);
        # create filename for sorted bam file
        my @bam_minus_path = split(/\//, $bam_minus);
        my $thisSortedBamFile = "$otherfilesDir/".$bam_minus_path[scalar(@bam_minus_path)-1];
        $thisSortedBamFile =~ s/\.bam/\.s\.bam/;
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString .= "$SAMTOOLS_PATH/samtools sort -\@ "
               .($CPU-1) . " -o $thisSortedBamFile "
               .  "$bam_minus "
               .  "1> $otherfilesDir/samtools_sort_minus_bam.stdout "
               .  "2> $errorfilesDir/samtools_sort_minus_bam.stderr";
        print LOG "\n$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n");
    }
    # merging and sorting unstranded bam files
    if(scalar(@unstranded_index) > 1){
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString .= "$BAMTOOLS_BIN_PATH/bamtools merge ";
        foreach (my $i = 0; $i < scalar(@unstranded_index); $i++) {
            chomp;
            $cmdString .= "-in $bam[$unstranded_index[$i]] ";
        }
        $cmdString .= "-out $bam_unstranded "
                   .  "1> $otherfilesDir/bam_unstranded.merge.log "
                   .  "2> $errorfilesDir/bam_unstranded.merge.err";
        print LOG "\n$cmdString\n" if ( $v > 3 );
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n");
    }elsif(scalar(@unstranded_index) == 1){
        $cmdString = "ln -s $bam[$unstranded_index[0]] $bam_unstranded";
        print LOG "\n$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n");
    }
    if(scalar(@unstranded_index > 0)){
        print LOG "\# " . (localtime) . ": sorting bam file $bam_unstranded...\n" 
            if ($v > 3);
        # create filename for sorted bam file
        my @bam_unstranded_path = split(/\//, $bam_unstranded);
        my $thisSortedBamFile = "$otherfilesDir/".$bam_unstranded_path[scalar(@bam_unstranded_path)-1];
        $thisSortedBamFile =~ s/\.bam/\.s\.bam/;
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString .= "$SAMTOOLS_PATH/samtools sort -\@ "
               .($CPU-1) . " -o $thisSortedBamFile "
               .  "$bam_unstranded "
               .  "1> $otherfilesDir/samtools_sort_unstranded_bam.stdout "
               .  "2> $errorfilesDir/samtools_sort_unstranded_bam.stderr";
        print LOG "\n$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line " . __LINE__ . "\nFailed to execute: $cmdString!\n");
    }
    my @names;
    if(-e $bam_plus){
        push(@names, "plus");
    }
    if(-e $bam_minus){
        push(@names, "minus");
    }
    if(-e $bam_unstranded){
        push(@names, "unstranded");
    }
    foreach(@names){
        $cmdString = "";
        my $thisWigFile = "$otherfilesDir/rnaseq_".$_.".s.bam";
        $thisWigFile =~ s/\.s\.bam/\.wig/;
        my $string = find(
            "bamToWig.py",      $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        my $pythonCmdString = "";
        if ($nice) {
            $pythonCmdString .= "nice ";
        }
        $pythonCmdString .= "$PYTHON3_PATH/python3 $string -b $otherfilesDir/rnaseq_"
                         .$_.".s.bam -g $genome -o $thisWigFile 2> $errorfilesDir/bamToWig_"
                         .$_.".err";
        print LOG "$pythonCmdString\n" if ($v > 3);
        system("$pythonCmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $pythonCmdString\n");
    }
}

####################### stranded_wig2ep_hints ##################################
# convert stranded wig files to exonpart hints for AUGUSTUS
################################################################################

sub stranded_wig2ep_hints {
    my $ep_hints_file = "$otherfilesDir/ep.hints";
    print LOG "\# " . (localtime)
        . ": Converting strand separated wig files to stranded ep hints.\n" 
        if ( $v > 3 );
    my $bam_plus = "$otherfilesDir/rnaseq_plus.s.bam";
    my $bam_minus = "$otherfilesDir/rnaseq_minus.s.bam";
    my $bam_unstranded = "$otherfilesDir/rnaseq_unstranded.s.bam";
    my @names;
    if(-e $bam_plus){
        push(@names, "plus");
    }
    if(-e $bam_minus){
        push(@names, "minus");
    }
    if(-e $bam_unstranded){
        push(@names, "unstranded");
    }
    foreach(@names){
        print LOG "\# " . (localtime) . ": Creating wiggle file for $_...\n"
            if ( $v > 3 );
        $cmdString = "";
        my $thisWigFile = "$otherfilesDir/rnaseq_".$_.".wig";
        my $this_ep_hints_file = $thisWigFile;
        $this_ep_hints_file =~ s/\.wig/\.ep\.hints/;
        if( not( uptodate( [$thisWigFile] , [$this_ep_hints_file] ) ) || $overwrite ){
            $string = find(
                "wig2hints.pl", $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
            );
            $perlCmdString = "";
            if( $nice ) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString .= "cat $thisWigFile | ";
            if( $nice ) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString .= "perl $string --margin=10 --minthresh=2 "
                           .  "--minscore=4 --prune=0.1 --src=W --type=ep "
                           .  "--radius=4.5 --pri=4 ";
            if($_ eq "plus"){
                $perlCmdString .=  "--UCSC=$otherfilesDir/plus.track  "
                               .  " --strand=\"+\"";
            }elsif($_ eq "minus"){
                $perlCmdString .=  "--UCSC=$otherfilesDir/minus.track  "
                               .  " --strand=\"-\"";
            }else{
                $perlCmdString .=  "--UCSC=$otherfilesDir/unstranded.track  "
                               .  " --strand=\".\"";
            }
            $perlCmdString .= "> $this_ep_hints_file "
                           .  "2> $errorfilesDir/wig2hints_$_.err";
            print LOG "\# "
                . (localtime)
                . ": Converting wiggle file to exonpart hints for AUGUSTUS\n"
                if ($v > 3);
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nFailed to execute: $perlCmdString\n");
        }
        if( not( uptodate( [$this_ep_hints_file], [$hintsfile] ) ) || $overwrite ) {
            $cmdString = "";
            if( $nice ) {
                $cmdString .= "nice ";
            }
            $cmdString .= "cat $this_ep_hints_file >> $hintsfile "
                   . "2> $errorfilesDir/cat_exonpart_to_hintsfile_$_.err";
            print LOG "\# "
                . (localtime)
                . ": Concatenating exonpart hints from $this_ep_hints_file "
                . "to $hintsfile:\n"
                if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nFailed to execute: $cmdString\n");
        }
    }    
}



####################### filter_augustus ########################################
# filter AUGUSTUS genes for those that have support by RNA-Seq hints with
# a minimal multiplicity of 10 in all introns (those genes will be used as
# starting point for UTR identification). Single exon genes are discarded.
################################################################################

sub filter_augustus {
    my $augustus_file = shift;
    print LOG "\# " . (localtime) 
        . ": Filtering $augustus_file for genes with strong intron support.\n"
        if ($v > 3);
    my %introns;
    open( HINTS, "<", $hintsfile ) or die( "ERROR in file "
        . __FILE__ . " at line " . __LINE__
        . "\nCould not open file $hintsfile!\n" );
    while(<HINTS>) {
        if( $_ =~ m/\tintron\t.*mult=(\d+)/ ) {
            if( $1 > 9 ) {
                my @line = split( /\t/, $_ );
                $introns{ $line[0] }{ $line[6] }{ $line[3] }{ $line[4] } = $line[5];
            }
        }
    }
    close( HINTS ) or die( "ERROR in file "
        . __FILE__ . " at line " . __LINE__
        . "\nCould not close file $hintsfile!\n" );
    my %tx;
    open( GENES, "<", $augustus_file ) or die( "ERROR in file "
        . __FILE__ . " at line " . __LINE__
        . "\nCould not open file $augustus_file!\n" );
    while(<GENES>){
        if($_ =~ m/transcript_id/) {
            my @line = split( /\t/, $_ );
            push( @{$tx{$line[8]}}, $_ );
        }
    }
    close( GENES ) or die( "ERROR in file "
        . __FILE__ . " at line " . __LINE__
        . "\nCould not close file $augustus_file!\n" );

    open( FGENES , ">", "$otherfilesDir/augustus.hints.f.gtf") or die ( 
        "ERROR in file " . __FILE__ . " at line " . __LINE__
        . "\nCould not open file $otherfilesDir/augustus.hints.f.gtf!\n" );
    while ( my ($txid, $txarray) = each (%tx) ) {
        my $printF = 1;
        my $nIntron = 0;
        foreach(@{$txarray}){
            my @line = split(/\t/);
            if( $line[2] eq "intron" ) {
                $nIntron++;
                if( not( defined( $introns{ $line[0] }{ $line[6] } { $line[3] } { $line[4] }) ) ) {
                    $printF = 0;
                }
            }
        }
        if( $printF == 1 && $nIntron > 0 ) {
            foreach(@{$txarray}){
                print FGENES $_;
            }
        }
    }
    close( FGENES ) or die ( "ERROR in file "
        . __FILE__ . " at line " . __LINE__
        . "\nCould not close file $otherfilesDir/augustus.hints.f.gtf!\n" );
}

####################### merge_transcript_sets ##################################
# * merge evidence anchored genemark predicted genes that are not contained 
#   in the augustus with hints gene set to produce braker.gtf
# * in case of esmode, merge the complete ab initio gene sets to produce 
#   braker.gtf
# * in case of utr predictions, produce braker.utr.gtf (but only CDS features 
#   are checked for identity during merging)
################################################################################

sub merge_transcript_sets {
    print LOG "\# " . (localtime) . ": Trying to create merged gene set from GeneMark-EX "
        . "and AUGUSTUS predictions (braker.gtf/braker.utr.gtf)...\n" if ($v > 3);
    my $localUtr = shift;
    $string = find(
        "merge_transcript_sets.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);

    if($ESmode == 1){ # exists only without utr
        if( (-e "$genemarkDir/genemark.gtf") and (-e "$otherfilesDir/augustus.ab_initio.gtf") ) {
            print LOG "# WARNING: in --esmode, braker will merge the complete ab inito gene sets of GeneMark-EX and AUGUSTUS."
                . "Genes contained in braker.gtf will be of much lower quality than if RNA-Seq data or ProtHint evidence had been provided.\n";
            $errorfile = "$errorfilesDir/merge_all_ab_initio_transcripts.stderr";
                    $perlCmdString = "";
                    if ($nice) {
                        $perlCmdString .= "nice ";
                    }
                    $perlCmdString .= "perl $string $otherfilesDir/augustus.ab_initio.gtf $genemarkDir/genemark.gtf 1> $otherfilesDir/braker.gtf 2>$errorfile";
                    print LOG "$perlCmdString\n" if ($v > 3);
                    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nFailed to execute: $perlCmdString\n");
        } 
    }else{
        if($localUtr eq "off"){
            if( ( (-e "$genemarkDir/genemark.f.multi_anchored.gtf") or (-e "$genemarkDir/genemark.f.single_anchored.gtf") ) && (-e "$otherfilesDir/augustus.hints.gtf") ){
                if( -e "$genemarkDir/genemark.f.multi_anchored.gtf") {
                    $errorfile = "$errorfilesDir/merge_transcripts_multi_anchored.stderr";
                    $perlCmdString = "";
                    if ($nice) {
                        $perlCmdString .= "nice ";
                    }
                    $perlCmdString .= "perl $string $otherfilesDir/augustus.hints.gtf $genemarkDir/genemark.f.multi_anchored.gtf 1> $otherfilesDir/braker.gtf 2>$errorfile";
                    print LOG "$perlCmdString\n" if ($v > 3);
                    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nFailed to execute: $perlCmdString\n");
                }
                if( -e "$genemarkDir/genemark.f.single_anchored.gtf" ) {
                    if( not( -e "$otherfilesDir/braker.gtf") ) {
                        $cmdString = "cp $otherfilesDir/augustus.hints.gtf $otherfilesDir/step2.gtf";
                        print LOG "$cmdString\n" if ($v > 3);
                        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
                            . " at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
                    } else {
                        $cmdString = "mv $otherfilesDir/braker.gtf $otherfilesDir/step2.gtf";
                        print LOG "$cmdString\n" if ($v > 3);
                        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
                            . " at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
                    }
                    $errorfile = "$errorfilesDir/merge_transcripts_single_anchored.stderr";
                    $perlCmdString = "";
                    if ($nice) {
                        $perlCmdString .= "nice ";
                    }
                    $perlCmdString .= "perl $string $otherfilesDir/step2.gtf $genemarkDir/genemark.f.single_anchored.gtf 1> $otherfilesDir/braker.gtf 2>$errorfile";
                    print LOG "$perlCmdString\n" if ($v > 3);
                    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nFailed to execute: $perlCmdString\n");
                    unlink("$otherfilesDir/step2.gtf") or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nFailed to remove file $otherfilesDir/step2.gtf\n");
                }
            }
        } else {
            if( ( (-e "$genemarkDir/genemark.f.multi_anchored.gtf") or (-e "$genemarkDir/genemark.f.single_anchored.gtf") ) && -e "$otherfilesDir/augustus.hints_utr.gtf") {
                if( -e "$genemarkDir/genemark.f.multi_anchored.gtf") {
                    $errorfile = "$errorfilesDir/merge_transcripts_multi_anchored_utr.stderr";
                    $perlCmdString = "";
                    if ($nice) {
                        $perlCmdString .= "nice ";
                    }
                    $perlCmdString .= "perl $string $otherfilesDir/augustus.hints_utr.gtf $genemarkDir/genemark.f.multi_anchored.gtf 1> $otherfilesDir/braker_utr.gtf 2>$errorfile";
                    print LOG "$perlCmdString\n" if ($v > 3);
                    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nFailed to execute: $perlCmdString\n");
                }
                if( -e "$genemarkDir/genemark.f.single_anchored.gtf" ) {
                    if( not( -e "$otherfilesDir/braker_utr.gtf") ) {
                        $cmdString = "cp $otherfilesDir/augustus.hints_utr.gtf $otherfilesDir/step2.gtf";
                        print LOG "$cmdString\n" if ($v > 3);
                        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
                            . " at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
                    } else {
                        $cmdString = "mv $otherfilesDir/braker_utr.gtf $otherfilesDir/step2.gtf";
                        print LOG "$cmdString\n" if ($v > 3);
                        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
                            . " at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
                    }
                    $errorfile = "$errorfilesDir/merge_transcripts_single_anchored_utr.stderr";
                    $perlCmdString = "";
                    if ($nice) {
                        $perlCmdString .= "nice ";
                    }
                    $perlCmdString .= "perl $string $otherfilesDir/step2.gtf $genemarkDir/genemark.f.single_anchored.gtf 1> $otherfilesDir/braker_utr.gtf 2>$errorfile";
                    print LOG "$perlCmdString\n" if ($v > 3);
                    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nFailed to execute: $perlCmdString\n");
                    unlink("$otherfilesDir/step2.gtf") or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nFailed to remove file $otherfilesDir/step2.gtf\n");
                }
            }
        }
    }
}

####################### wig2hints ##############################################
# convert wiggle file (from RNA-Seq) to ep hints (only required for AUGUSTUS
# prediction with UTRs)
####################### wig2hints ##############################################

sub wig2hints {
    my $wiggle = "$otherfilesDir/merged.wig";
    my $ep_hints_file = "$otherfilesDir/ep.hints";
    if( not( uptodate( [$wiggle] , [$ep_hints_file] ) ) || $overwrite ){
        $string = find(
            "wig2hints.pl", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $perlCmdString = "";
        if( $nice ) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "cat $wiggle | ";
        if( $nice ) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string --margin=10 --minthresh=2 --minscore=4 "
                       .  "--prune=0.1 --src=W --type=ep "
                       .  "--UCSC=$otherfilesDir/unstranded.track --radius=4.5 "
                       .  "--pri=4 --strand=\".\" > $ep_hints_file "
                       .  "2> $errorfilesDir/wig2hints.err";
        print LOG "\# "
            . (localtime)
            . ": Converting wiggle file to exonpart hints for AUGUSTUS\n"
            if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $perlCmdString\n");
    }
    if( not( uptodate( [$ep_hints_file], [$hintsfile] ) ) || $overwrite ) {
        $cmdString = "";
        if( $nice ) {
            $cmdString .= "nice ";
        }
        $cmdString .= "cat $ep_hints_file >> $hintsfile 2> $errorfilesDir/cat_exonpart_to_hintsfile.err";
        print LOG "\# "
            . (localtime)
            . ": Concatenating exonpart hints from $ep_hints_file to $hintsfile:\n"
            if ($v > 3);
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
    }
}


####################### gtf2gff3 ###############################################
# convert gtf to gff3 format
# (do not use native AUGUSTUS gff3 output because joingenes does not produce
# gff3 format)
####################### gtf2gff3 ###############################################

sub gtf2gff3 {
    my $gtf = shift;
    my $gff3 = shift;
    print LOG "\# " . (localtime) . ": converting gtf file $gtf to gff3 format "
        . ", outputfile $gff3.\n" if ($v > 2);
    if( not( uptodate( [$gtf] , [$gff3] ) ) || $overwrite ){
        $string = find(
            "gtf2gff.pl", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $perlCmdString = "";
        if($nice){
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "cat $gtf | perl -ne 'if(m/\\tAUGUSTUS\\t/) {"
                       .  "print \$_;}' | perl $string --gff3 --out=$gff3 "
                       .   ">> $otherfilesDir/gtf2gff3.log "
                       .   "2>> $errorfilesDir/gtf2gff3.err";
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $perlCmdString\n");
    }else{
        print LOG "\# " . (localtime) . ": skipping format conversion because "
            . "files are up to date.\n" if ($v > 2);
    }
}

####################### all_preds_gtf2gff3 #####################################
# convert gtf to gff3 format for the following possible final output files:
#  * augustus.ab_initio.gtf
#  * augustus.hints.gtf
#  * augustus.ab_initio_utr.gtf
#  * augustus.hints_utr.gtf
####################### all_preds_gtf2gff3 #####################################

sub all_preds_gtf2gff3 {
    print LOG "\# " . (localtime) . ": converting essential output files "
        . "to gff3 format.\n" if ($v > 2);
    my @files = ("$otherfilesDir/augustus.ab_initio.gtf", 
        "$otherfilesDir/augustus.hints.gtf",
        "$otherfilesDir/augustus.ab_initio_utr.gtf",
        "$otherfilesDir/augustus.hints_utr.gtf",
        "$otherfilesDir/braker.gtf",
        "$otherfilesDir/braker_utr.gtf");
    foreach(@files){
        if(-e $_){
            my $gtf = $_;
            my $gff3 = $_;
            $gff3 =~ s/\.gtf/\.gff3/;
            gtf2gff3($gtf, $gff3);
        }
    }
}

####################### make_hub ################################################
# create track data hub for visualizing BRAKER results with the UCSC Genome
# Browser using make_hub.py
####################### make_hub ################################################

sub make_hub {
    print LOG  "\# " . (localtime) . ": generating track data hub for UCSC "
           . " Genome Browser\n" if ($v > 2);

    print CITE $pubs{'makehub'}; $pubs{'makehub'} = "";

    my $cmdStr = $PYTHON3_PATH . "/python3 " . $MAKEHUB_PATH . "/make_hub.py -g " . $genome 
            . " -e " . $email . " -l " . "hub_" . substr($species, 0, 3) 
            . " -L " . $species . " -X " . $otherfilesDir . " -P ";
    if ($annot) {
        $cmdStr .= "-a $annot";
    }
    $cmdStr .= " > $otherfilesDir/makehub.log 2> $errorfilesDir/makehub.err";
    print LOG $cmdStr . "\n"  if ($v > 3);
    if (@bam) {
        print LOG "BAM tracks are not automatically generated for saving "
               . "run time; if you want to "
               . "add BAM track(s), run:\n" 
               .  $PYTHON3_PATH . "/python3 " . $MAKEHUB_PATH . " -l " 
               . "hub_" . substr($species, 0, 3) . " -e " . $email . " -A " 
               . " -B ";
        foreach(@bam){
            print LOG "$_ ";
        }
        print LOG "-c " . $CPU . "\n";
    }
    system("$cmdStr") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdStr\n");
}

####################### clean_up ###############################################
# delete empty files, and files produced by parallelization
####################### clean_up ###############################################

sub clean_up {
    print LOG "\# " . (localtime) . ": deleting empty files\n" if ($v > 2);
    if ($nice) {
        print LOG "\# " . (localtime) . ": nice find $otherfilesDir -empty\n"
        if ($v > 3);
        @files = `nice find $otherfilesDir -empty`;
    }
    else {
        print LOG "\# " . (localtime) . ": find $otherfilesDir -empty\n"
            if ($v > 3);
        @files = `find $otherfilesDir -empty`;
    }
    for ( my $i = 0; $i <= $#files; $i++ ) {
        chomp( $files[$i] )
            ; # to prevent error: Unsuccessful stat on filename containing newline
        if ( -f $files[$i] ) {
            print LOG "rm $files[$i]\n" if ($v > 3);
            unlink( rel2abs( $files[$i] ) );
        }
    }
    # deleting files from AUGUSTUS parallelization
    if($cleanup){
        print LOG "\# " . (localtime) . ": deleting job lst files (if existing)\n"
            if ($v > 3);
        opendir( DIR, $otherfilesDir ) or die("ERROR in file " . __FILE__
            . " at line ". __LINE__
            . "\nFailed to open directory $otherfilesDir!\n");
        while ( my $file = readdir(DIR) ) {
            if( $file =~ m/\.lst/ || $file =~ m/aug_ab_initio_/ || $file =~ m/Ppri5/ || $file =~ m/augustus\.E/ 
                || $file =~ m/gff\.E/ || 
                $file =~ m/missed/ || $file =~ m/prot_hintsfile\.aln2hints\.temp\.gff/ ||
                $file =~ m/aa2nonred\.stdout/ || $file =~ m/augustus\.hints\.tmp\.gtf/ ||
                $file =~ m/firstetraining\.stdout/ || $file =~ m/gbFilterEtraining\.stdout/
                || $file =~ m/secondetraining\.stdout/ || $file =~ m/traingenes\.good\.fa/ ||
                $file =~ m/aa2nonred\.stdout/ || $file =~ m/singlecds\.hints/ ||
                $file =~ m/augustus\.hints\.tmp\.gtf/ || $file =~ m/train\.gb\./ ||
                $file =~ m/traingenes\.good\.fa/ || $file =~ m/augustus\.ab_initio\.tmp\.gtf/
                || $file =~ m/augustus\.ab_initio_utr\.tmp\.gtf/ || $file =~ m/augustus\.hints_utr\.tmp\.gtf/
                || $file =~ m/genes\.gtf/ || $file =~ m/genes_in_gb\.gtf/ ||
                $file =~ m/merged\.s\.bam/ || $file =~ m/utr_genes_in_gb\.fa/ ||
                $file =~ m/utr_genes_in_gb\.nr\.fa/ || $file =~ m/utr\.gb\.test/ ||
                $file =~ m/utr\.gb\.train/ || $file =~ m/utr\.gb\.train\.test/ ||
                $file =~ m/utr\.gb\.train\.train/ || $file =~ m/ep\.hints/ || 
                $file =~ m/rnaseq\.utr\.hints/ || $file =~ m/stops\.and\.starts.gff/ ||
                $file =~ m/trainGb3\.train/ || $file =~ m/traingenes\.good\.nr.\fa/ ||
                $file =~ m/nonred\.loci\.lst/ || $file =~ m/traingenes\.good\.gtf/ ||
                $file =~ m/etrain\.bad\.lst/ || $file =~ m/etrain\.bad\.lst/ ||
                $file =~ m/train\.f*\.gb/ || $file =~ m/good_genes\.lst/ || 
                $file =~ m/traingenes\.good\.nr\.fa/ || $file =~ m/fix_IFS_log_/ || 
                $file =~ m/tmp_merge_hints\.gff/ || $file =~ m/tmp_no_merge_hints\.gff/ ){
                print LOG "rm $otherfilesDir/$file\n" if ($v > 3);
                unlink( "$otherfilesDir/$file" );
            }
        }

        if(-e "$otherfilesDir/seqlist"){
            unlink ( "$otherfilesDir/seqlist" );
        }
        if(-d "$otherfilesDir/genome_split" ) {
            rmtree( ["$otherfilesDir/genome_split"] ) or die ("ERROR in file "
                . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete $otherfilesDir/genome_split!\n");
        }
        if(-d "$otherfilesDir/tmp_opt_$species") {
            rmtree( ["$otherfilesDir/tmp_opt_$species"] ) or die ("ERROR in file "
                . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete $otherfilesDir/tmp_opt_$species!\n");
        }
        if(-d "$otherfilesDir/augustus_files_E"){
            rmtree ( ["$otherfilesDir/augustus_files_E"] ) or die ("ERROR in file "
                . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete $otherfilesDir/augustus_files_E!\n");
        }
        if(-d "$otherfilesDir/augustus_files_Ppri5"){
            rmtree ( ["$otherfilesDir/augustus_files_Ppri5"] ) or die ("ERROR in file "
                . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete $otherfilesDir/augustus_files_Ppri5!\n");
        }
        # clean up ProtHint output files
        if(-e "$otherfilesDir/evidence_augustus.gff"){
            print LOG "rm $otherfilesDir/evidence_augustus.gff\n" if ($v > 3);
            unlink("$otherfilesDir/evidence_augustus.gff");
        }
        if(-e "$otherfilesDir/gene_stat.yaml"){
            print LOG "rm $otherfilesDir/gene_stat.yaml\n" if ($v > 3);
            unlink("$otherfilesDir/gene_stat.yaml");
        }
        if(-e "$otherfilesDir/gmes_proteins.faa"){
            print LOG "rm $otherfilesDir/gmes_proteins.faa\n" if ($v > 3);
            unlink("$otherfilesDir/gmes_proteins.faa");
        }
        if(-e "$otherfilesDir/nuc.fasta"){
            print LOG "rm $otherfilesDir/nuc.fasta\n" if ($v > 3);
            unlink("$otherfilesDir/nuc.fasta");
        }
        if(-e "$otherfilesDir/prothint_augustus.gff"){
            print LOG "rm $otherfilesDir/prothint_augustus.gff\n" if ($v > 3);
            unlink("$otherfilesDir/prothint_augustus.gff");
        }
        if(-e "$otherfilesDir/prothint_reg.out"){
            print LOG "rm $otherfilesDir/prothint_reg.out\n" if ($v > 3);
            unlink("$otherfilesDir/prothint_reg.out");
        }
        if(-e "$otherfilesDir/top_chains.gff"){
            print LOG "rm $otherfilesDir/top_chains.gff\n" if ($v > 3);
            unlink("$otherfilesDir/top_chains.gff");
        }
        if(-d "$otherfilesDir/diamond"){
            print LOG "rm -r $otherfilesDir/diamond\n" if ($v > 3);
            rmtree ( ["$otherfilesDir/diamond"] ) or die ("ERROR in file "
                . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete $otherfilesDir/diamond!\n");
        }
        if(-d "$otherfilesDir/Spaln"){
            print LOG "rm -r $otherfilesDir/Spaln\n" if ($v > 3);
            rmtree ( ["$otherfilesDir/Spaln"] ) or die ("ERROR in file "
                . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete $otherfilesDir/Spaln!\n");
        }


        $string = find(
            "braker_cleanup.pl", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $perlCmdString = "";
        if($nice){
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string --wdir=$otherfilesDir";
        print LOG "$perlCmdString\n" if ($v > 3);
        my $loginfo = `$perlCmdString`;
        print LOG $loginfo;
    }
}


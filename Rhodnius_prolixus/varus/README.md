## Running VARUS

VARUS was run on March 24, 2020.

```bash
runVARUS.pl --aligner=HISAT --readFromTable=0 --createindex=1 --latinGenus=Rhodnius \
    --latinSpecies=prolixus --speciesGenome=../data/genome.fasta.masked --logfile=varus_log > log
cp Rhodnius_prolixus/cumintrons.stranded.gff varus.gff
```

The output of VARUS is included.

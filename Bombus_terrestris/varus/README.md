## Running VARUS

VARUS was run on March 24, 2020.

```bash
runVARUS.pl --aligner=HISAT --readFromTable=0 --createindex=1 --latinGenus=Bombus \
    --latinSpecies=terrestris --speciesGenome=../data/genome.fasta.masked --logfile=varus_log > log
cp Bombus_terrestris/cumintrons.stranded.gff varus.gff
```

The output of VARUS is included.

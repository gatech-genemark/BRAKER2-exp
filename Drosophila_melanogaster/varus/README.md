## Running VARUS

VARUS was run on January 22, 2020.

```bash
runVARUS.pl --aligner=HISAT --readFromTable=0 --createindex=1 --latinGenus=Drosophila \
    --latinSpecies=melanogaster --speciesGenome=../data/genome.fasta.masked --logfile=varus_log > log
cp Drosophila_melanogaster/cumintrons.stranded.gff varus.gff
```

The output of VARUS is included.

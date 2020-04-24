## Running VARUS

VARUS was run on March 24, 2020.

```bash
runVARUS.pl --aligner=HISAT --readFromTable=0 --createindex=1 --latinGenus=Xenopus \
    --latinSpecies=tropicalis --speciesGenome=../data/genome.fasta.masked --logfile=varus_log > log
cp Xenopus_tropicalis/cumintrons.stranded.gff varus.gff
```

The output of VARUS is included.

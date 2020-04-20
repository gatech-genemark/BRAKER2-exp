## Preparation of proteins

Download vertebrata proteins from OrthoDB

```bash
wget https://v100.orthodb.org/download/odb10_vertebrata_fasta.tar.gz
tar xvf odb10_vertebrata_fasta.tar.gz
rm odb10_vertebrata_fasta.tar.gz
```

Download metazoa proteins from OrthoDB

```bash
wget https://v100.orthodb.org/download/odb10_metazoa_fasta.tar.gz
tar xvf odb10_metazoa_fasta.tar.gz
rm odb10_metazoa_fasta.tar.gz
```

Add missing chordata to vertebrata from metazoa and rename to chordata

```bash
# Branchiostoma belcheri
cp metazoa/Rawdata/7741_0.fs vertebrate/Rawdata/
# Branchiostoma floridae
cp metazoa/Rawdata/7739_0.fs vertebrate/Rawdata/
# Ciona intestinalis
cp metazoa/Rawdata/7719_0.fs vertebrate/Rawdata/
mv vertebrate chordata
```

Function for creating a single fasta file with metazoa proteins, excluding
species supplied in a list.

```bash
createProteinFile() {
    excluded=$1
    output=$2

    # Get NCBI ids of species in excluded list
    grep -f <(paste <(yes $'\n'| head -n $(cat $excluded | wc -l)) \
        $excluded <(yes $'\n'| head -n $(cat $excluded | wc -l))) \
        ../../OrthoDB/odb10v0_species.tab | cut -f2 | sed "s/_0//" > ids

    # Create protein file with everything else
    cat $(ls -d chordata/Rawdata/* | grep -v -f ids) > $output

    # Remove dots from file
    sed -i -E "s/\.//" $output

    rm ids
}
```

Create protein databases with different levels of exclusion. Exclusion lists
correspond to species in taxonomic levels in OrthoDB v10.

```bash
createProteinFile cypriniformes.txt order_excluded.fa
```

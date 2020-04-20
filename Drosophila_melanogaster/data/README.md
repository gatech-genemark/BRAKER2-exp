## Preparation of protein sets

Download arthropoda proteins from OrthoDB

```bash
wget https://v100.orthodb.org/download/odb10_arthropoda_fasta.tar.gz
tar xvf odb10_arthropoda_fasta.tar.gz
rm odb10_arthropoda_fasta.tar.gz
```

Function for creating a single fasta file with arthropda proteins, excluding
species supplied in a list.

```bash
createProteinFile() {
    excluded=$1
    output=$2

    # Get NCBI ids of species in excluded list
    grep -f <(paste <(yes $'\n'| head -n $(cat $excluded | wc -l)) \
       	$excluded <(yes $'\n'| head -n $(cat $excluded | wc -l))) \
       	../../OrthoDB/odb10v0_species.tab | cut -f2 > ids

    # Create protein file with everything else
    cat $(ls -d arthropoda/Rawdata/* | grep -v -f ids) > $output

    # Remove dots from file
    sed -i -E "s/\.//" $output

    rm ids
}
```

Create protein databases with different levels of exclusion. Exclusion lists
correspond to species in taxonomic levels in OrthoDB v10.

```bash
createProteinFile drosophila_melanogaster.txt species_excluded.fa
createProteinFile drosophila.txt family_excluded.fa
createProteinFile diptera.txt order_excluded.fa
```

## Preparation of a random set of proteins

The set contains proteins from random 25 arthropoda species which reside beyond
Diptera taxonomical order.

```bash
# Get NCBI ids of species in excluded list
grep -f <(paste <(yes $'\n'| head -n $(cat diptera.txt | wc -l)) \
    diptera.txt <(yes $'\n'| head -n $(cat diptera.txt | wc -l))) \
    ../../OrthoDB/odb10v0_species.tab | cut -f2 > ids

# Create protein file with everything else
cat $(ls -d arthropoda/Rawdata/* | grep -v -f ids | shuf | head -25) > order_excluded_25.fa

# Remove dots from file
sed -i -E "s/\.//" order_excluded_25.fa

rm ids
```

Same command were used to prepare the subset of 10 species, only replacing the number 25 by 10 in

```bash
cat $(ls -d arthropoda/Rawdata/* | grep -v -f ids | shuf | head -10) > order_excluded_10.fa
```

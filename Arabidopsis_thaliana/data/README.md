## Preparation of proteins

Download plants proteins from OrthoDB

```bash
wget https://v100.orthodb.org/download/odb10_plants_fasta.tar.gz
tar xvf odb10_plants_fasta.tar.gz
rm odb10_plants_fasta.tar.gz
```

Function for creating a single fasta file with plant proteins, excluding
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
    cat $(ls -d plants/Rawdata/* | grep -v -f ids) > $output

    # Remove dots from file
    sed -i -E "s/\.//" $output

    rm ids
}
```

Create protein databases with different levels of exclusion. Exclusion lists
correspond to species in taxonomic levels in OrthoDB v10.

```bash
createProteinFile arabidopsis_thaliana.txt species_excluded.fa
createProteinFile brassicaceae.txt family_excluded.fa
createProteinFile brassicales.txt order_excluded.fa
```

## Preparation of a random set of proteins

The set contains proteins from random 10 plant species which reside beyond
brassicales taxonomical order.

```bash
# Get NCBI ids of species in excluded list
grep -f <(paste <(yes $'\n'| head -n $(cat brassicales.txt | wc -l)) \
    brassicales.txt <(yes $'\n'| head -n $(cat brassicales.txt | wc -l))) \
    ../../OrthoDB/odb10v0_species.tab | cut -f2 > ids

# Create protein file with everything else
cat $(ls -d plants/Rawdata/* | grep -v -f ids | shuf | head -10) > order_excluded_10.fa

# Remove dots from file
sed -i -E "s/\.//" order_excluded_10.fa

rm ids
```


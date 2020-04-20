## Preparation of proteins

Download metazoa proteins from OrthoDB

```bash
wget https://v100.orthodb.org/download/odb10_metazoa_fasta.tar.gz
tar xvf odb10_metazoa_fasta.tar.gz
rm odb10_metazoa_fasta.tar.gz
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
       	../../OrthoDB/odb10v0_species.tab | cut -f2 > ids

    # Create protein file with everything else
    cat $(ls -d metazoa/Rawdata/* | grep -v -f ids) > $output

    # Remove dots from file
    sed -i -E "s/\.//" $output

    rm ids
}
```

Create protein databases with different levels of exclusion. Exclusion lists
correspond to species in taxonomic levels in OrthoDB v10.

```bash
createProteinFile caenorhabditis_elegans.txt species_excluded.fa
createProteinFile caenorhabditis.txt family_excluded.fa
createProteinFile rhabditida.txt order_excluded.fa
```

## Preparation of a random set of proteins

The set contains proteins from random 10 metazoan species which reside beyond
Rhabditida taxonomical order.

```bash
# Get NCBI ids of species in excluded list
grep -f <(paste <(yes $'\n'| head -n $(cat rhabditida.txt | wc -l)) \
    rhabditida.txt <(yes $'\n'| head -n $(cat rhabditida.txt | wc -l))) \
    ../../OrthoDB/odb10v0_species.tab | cut -f2 > ids

# Create protein file with everything else
cat $(ls -d metazoa/Rawdata/* | grep -v -f ids | shuf | head -10) > order_excluded_10.fa

# Remove dots from file
sed -i -E "s/\.//" order_excluded_10.fa

rm ids
```

#!/usr/bin/env bash
#
# Tomas Bruna
# This script initializes a folder structure for a new test species

prothintFiles="prothint.gff prothint_augustus.gff evidence.gff evidence_augustus.gff"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 species_name exclusion_level_1 ... exclusion_level_n"
    echo "Example: $0 Drosophila_melanogaster species family order"
    exit
fi

species=$1

if [ -d "$species" ]; then
    >&2 echo "Species directory already exists. Exiting."
    exit
fi

shift
exclusionLevels=("$@")


mkdir "$species"; cd "$species"

touch README.md

# Annotation folder
mkdir annot
ln -s ../../../EukSpecies/$species/annot/{annot.gtf,pseudo.gff3} annot

# Data folder
mkdir data
ln -s "../../../EukSpecies/$species/data/genome.fasta.masked" data

# ProtHint folders
for level in "${exclusionLevels[@]}"; do
    mkdir -p prothint/${level}_excluded
    echo -n $prothintFiles | xargs -d " " -I{} ln -s \
            "../../../../prothint-ep-exp/$species/${level}_excluded/{}" \
            "prothint/${level}_excluded"
done

# ES folder
mkdir es
ln -s "../../../prothint-ep-exp/$species/ESm/genemark.gtf" es

# EP folders
for level in "${exclusionLevels[@]}"; do
    mkdir -p ep/${level}_excluded/{train,plus}
    echo -n "train plus" | xargs -d " " -I{} ln -s \
            "../../../../../prothint-ep-exp/$species/${level}_excluded/EP/{}/genemark.gtf" \
            "ep/${level}_excluded/{}"
done

# BRAKER2 folders
for level in "${exclusionLevels[@]}"; do
    mkdir -p braker2/${level}_excluded
    touch braker2/${level}_excluded/.gitkeep
done

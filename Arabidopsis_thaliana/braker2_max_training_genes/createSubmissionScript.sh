#!/usr/bin/env bash
# ==============================================================
# Tomas Bruna
# 2020
#
# Generate a pbs submission script for submitting a BRAKER2 jobs
# with max training genes limited to $n_genes
#
# ==============================================================

if [ ! "$#" -eq 1 ]; then
    echo "Usage: $0 n_genes"
    exit
fi

nGenes=$1

mkdir $nGenes
cd $nGenes

script="$nGenes.sh"

echo -n "#!/bin/sh
#
#PBS -N at_n_$nGenes
#PBS -l walltime=340:00:00
#PBS -l nodes=1:ppn=8:hdd
#PBS -m abe
#PBS -M bruna.tomas@gmail.com

SPECIES=Arabidopsis_thaliana
e=genus_excluded
genes=$nGenes

d=/storage3/braker2-exp/Arabidopsis_thaliana/braker2_max_training_genes

cd \$d/\$genes

s=braker2_ep_\${e}_\$genes

if [ -d /home/braker/project3/bin/Augustus/config/species/\$s ]; then
    rm -r /home/braker/project3/bin/Augustus/config/species/\$s
fi

PATH=/home/braker/bin/eval:/home/braker/project3/bin/MakeHub:/home/braker/project3/bin/kentUtils/bin:\$PATH

/home/braker/project4/bin/BRAKER-max-train-genes/scripts/braker.pl --maxTrainGenes=\$genes --skipIterativePrediction --hints=\$d/hintsfile.gff --prothints=\$d/prothint.gff --evidence=\$d/evidence.gff --geneMarkGtf=\$d/genemark.gtf --genome=/home/braker/project4/\${SPECIES}/data/genome.fasta.masked --softmasking --cores=8 --AUGUSTUS_CONFIG_PATH=/home/braker/project3/bin/Augustus/config --species=\$s --GENEMARK_PATH=/storage3/prothint-ep-exp/bin/GeneMarkES/bin --DIAMOND_PATH=/home/katharina/project3/bin/diamond/bin  --PYTHON3_PATH=/usr/local/bin --eval=/home/braker/project4/\${SPECIES}/annot/annot.gtf --AUGUSTUS_ab_initio --eval_pseudo=/home/braker/project4/\${SPECIES}/annot/pseudo.gff3 --epmode &> \${s}.log
" > $script

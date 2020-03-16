#!/usr/bin/env bash
# ==============================================================
# Tomas Bruna
# 2020
#
# Create a table for given header and rows from braker eval summary
#
# ==============================================================

if [ ! "$#" -eq 2 ]; then
    echo "Usage: header feature"
    exit
fi

header=$1
feature=$2

printRow() {
    genes=$1
    eval=$genes/braker/eval.summary
    column=$(cat $eval | sed -E "s/\/storage3\/braker2-exp\/Arabidopsis_thaliana\/braker2_max_training_genes\/[0-9]+\/braker\///g" | sed -E "s/$/\t/" | grep -Po ".*${header}\t" | tr -dc "\t" | wc -c)
    paste <(echo $genes) <(echo $(cut -f1,$column $eval | grep ${feature}_S | cut -f2 | tr "\n" "\t"  | sed -E "s/\t$/\n/"))
}

printRow 500

for i in {1000..12000..1000}; do
    printRow $i
done

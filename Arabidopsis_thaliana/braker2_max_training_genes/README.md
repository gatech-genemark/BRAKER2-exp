```bash
# Create pbs submission scripts

./createSubmissionScript.sh 500
seq 1000 1000 12000 | xargs -I {} ./createSubmissionScript.sh {}

# Tables generation

./createTable.sh augustus.ab_initio.gtf Gene > ab_initio.genes
./createTable.sh augustus.ab_initio.gtf Exon > ab_initio.cds

# Visualize
gnuplot -e "in='ab_initio.genes';title='$(pwd | cut -f 4,6 -d "/")'"  ../../../../bin/max_training_genes_accuracies.gp
gnuplot -e "in='ab_initio.cds';title='$(pwd | cut -f 4,6 -d "/")'"  ../../../../bin/max_training_genes_accuracies.gp
```

#!/usr/bin/env bash
# ==============================================================
# Tomas Bruna
#
# Create a table comparing gene and exon level sensitivity against
# different sets of annotated genes. The columns are
# * Raw annot: Raw annotation in which partial CDS are not distinguished
#   from full CDS
# * Partial CDS removed: Annotation with removed partial CDS exons. This removes
#   some genes completely (single exon genes) and creates many incomplete transcripts
#   and genes.
# * Complete transcripts: Complete transcripts only (no partial CDS were
#   in the transcripts)
# * Incomplete transcripts: Incomplete transcripts only (at least one partial
#   CDS was in each transcripts).
# * Complete genes: Genes in which all transcripts are complete
# * Incomplete genes: Genes in which at least one transcript is incomplete.
#
# The annot folder needs to contain all those different gene sets
# ==============================================================


getColumn() {
    header="$1"
    annot="$2"
    echo $header
    "$(dirname $0)/compare_intervals_exact.pl" --f1 $annot \
        --f2 $prediction --gene --pseudo $annotFolder/pseudo.gff3 | head -2 | tail -1 | cut -f4
    "$(dirname $0)/compare_intervals_exact.pl" --f1 $annot \
        --f2 $prediction --cds --pseudo $annotFolder/pseudo.gff3 | head -2 | tail -1 | cut -f4
    "$(dirname $0)/compare_intervals_exact.pl" --f1 <(grep Internal $annot) \
        --f2 pred.internal --cds --pseudo $annotFolder/pseudo.gff3 | head -2 | tail -1 | cut -f4
}

appendColumn() {
    column="$1"
    table="$(paste <(echo "$table") <(echo "$column"))"
}


if [ "$#" -ne 2 ]; then
    echo "Usage: $0 annot_folder prediction.gtf"
    exit
fi

annotFolder="$1"
prediction="$2"

incompleteTranscriptsWithCDS=$(mktemp)
incompleteGenesWithCDS=$(mktemp)

sed "s/CDS_partial/CDS/" $annotFolder/incompleteTranscripts.gtf > $incompleteTranscriptsWithCDS
sed "s/CDS_partial/CDS/" $annotFolder/incompleteGenes.gtf > $incompleteGenesWithCDS

table=$(echo -e "------\nGene_Sn\nExon_Sn\nInternal_Exon_Sn")

$(dirname $0)/categorize_exons.py $prediction pred

appendColumn "$(getColumn "Raw_annot" "$annotFolder/annot_raw.gtf")"
appendColumn "$(getColumn "Partial_CDS_removed" "$annotFolder/annot.gtf")"
appendColumn "$(getColumn "Complete_transcripts" "$annotFolder/completeTranscripts.gtf")"
appendColumn "$(getColumn "Incomplete_transcripts" "$incompleteTranscriptsWithCDS")"
appendColumn "$(getColumn "Complete_genes" "$annotFolder/completeGenes.gtf")"
appendColumn "$(getColumn "Incomplete_genes" "$incompleteGenesWithCDS")"

echo "$table"

rm pred.initial pred.internal pred.terminal pred.single $incompleteTranscriptsWithCDS $incompleteGenesWithCDS

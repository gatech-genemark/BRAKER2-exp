#!/usr/bin/env bash
# ==============================================================
# Tomas Bruna
#
# Create a table comparing performance against a set of genes
# that have all introns supported by RNA-Seq vs the rest.
#
# Single exon genes are excluded from this analysis
# ==============================================================


getColumn() {
    header=$1
    annotation=$2
    prediction=$3
    echo $header
    "$(dirname $0)/compute_accuracies.sh" $annotation \
        $pseudo $prediction $types | grep Sn | cut -f2
}

appendColumn() {
    column="$1"
    table="$(paste <(echo "$table") <(echo "$column"))"
}

getCount() {
    type=$1
    file=$2
    "$(dirname $0)/compare_intervals_exact.pl" --f1 $file \
        --f2 $file --$type | cut -f1 | head -2 | tail -1
}


if  [ "$#" -lt 4 ]; then
    echo "Usage: $0 pred.gtf annot.gtf pseudo.gff introns.gff"
    exit
fi

pred=$1
annot=$2
pseudo=$3
introns=$4

supported=$(mktemp)
unsupported=$(mktemp)
multi=$(mktemp)

grep -v Single $annot > $multi

$(dirname $0)/select_by_introns.pl --in_gtf $annot --out_gtf $supported \
    --in_introns $introns --no_phase --v >/dev/null
$(dirname $0)/select_by_introns.pl --in_gtf $annot --out_gtf $unsupported \
    --in_introns $introns --no_phase --v  --reverse >/dev/null


types="gene trans cds"

table=$(echo -e "-------\nGene_Sn------\nTranscript_Sn\nExon_Sn------")

appendColumn "$(getColumn Supported $supported $pred)"
appendColumn "$(getColumn Unsupported $unsupported $pred)"
appendColumn "$(getColumn All $multi $pred)"
echo "$table"

# Internal exon

types="cds"
$(dirname $0)/categorize_exons.py $pred pred

table=$(echo -e "Internal_Sn--")
appendColumn "$(getColumn Supported <(grep Internal $supported) pred.internal | tail -1)"
appendColumn "$(getColumn Usupported <(grep Internal $unsupported) pred.internal | tail -1)"
appendColumn "$(getColumn All <(grep Internal $multi) pred.internal | tail -1)"
echo "$table"


supportedGenes=$(getCount gene $supported)
supportedIntrons=$(getCount intron $supported)
unsupportedGenes=$(getCount gene $unsupported)
unsupportedIntrons=$(getCount intron $unsupported)
allGenes=$(getCount gene $multi)
allIntrons=$(getCount intron $multi)

echo
echo "--Supported set--"
printf "Genes: %d (%.2f%%)\n" $supportedGenes $(bc -l <<< "100*$supportedGenes/$allGenes")
echo "Introns: $supportedIntrons"
printf "Introns per gene %.2f\n" $(bc -l <<< $supportedIntrons/$supportedGenes)

echo
echo "--Unsupported set--"
printf "Genes: %d (%.2f%%)\n" $unsupportedGenes $(bc -l <<< "100*$unsupportedGenes/$allGenes")
echo "Introns: $unsupportedIntrons"
printf "Introns per gene %.2f\n" $(bc -l <<< $unsupportedIntrons/$unsupportedGenes)

rm $multi $supported $unsupported pred.internal pred.initial pred.terminal pred.single

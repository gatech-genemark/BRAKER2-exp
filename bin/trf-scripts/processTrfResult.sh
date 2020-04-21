#!/usr/bin/env bash
#
# Tomas Bruna
# Parse reults of TRF and collect various statistics about
# how much sequnec is masked by repeats, repeat properties,
# by period length, how much sequence is newly masked with,
# respect to existing masking, etc...

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 trf.dat minCopies originalGenome soft_mask title"
    exit
fi

trfOutput=$1
minCopies=$2
genome=$3
soft_mask=$4
title=$5

$(dirname $0)/parseTrfOutput.py $trfOutput --minCopies $minCopies --statistics STATS --gc > $1.c.${minCopies}.raw.gff

probuildOut=$(mktemp)
probuild --stat --details --seq $genome > $probuildOut
GC=$(cat $probuildOut | grep GC | tr -s " " | cut -f2 -d " ")
rm $probuildOut

filetitle=$(echo $title | tr -d " ")

$(dirname $0)/plot_stats.py STATS.periodCounts $filetitle-periodCounts_100.png --xmax 100 --title "$title: Period counts"
$(dirname $0)/plot_stats.py STATS.periodCounts $filetitle-periodCounts.png --title "$title: Period counts"

$(dirname $0)/plot_stats.py STATS.periodSeqLengths $filetitle-seqLengths_100.png --xmax 100 --yLabel "Sequence Length (Mb)" --scaleY 1000000 --title "$title: Sequence length per period size"
$(dirname $0)/plot_stats.py STATS.periodSeqLengths $filetitle-seqLengths.png --yLabel "Sequence Length (Mb)" --scaleY 1000000 --title "$title: Sequence length per period size"

$(dirname $0)/plot_stats.py STATS.GC $filetitle-gc_100.png --xmax 100 --title "$title: GC content per period size" --line $(bc -l  <<< $GC/100)
$(dirname $0)/plot_stats.py STATS.GC $filetitle-gc.png --title "$title: GC content per period size" --line $(bc -l  <<< $GC/100)

sorted=$(mktemp)
sort -k1,1 -k4,4n -k5,5n  $1.c.${minCopies}.raw.gff > $sorted
bedtools merge -i $sorted | awk 'BEGIN{OFS="\t"} {print $1,"trf","repeat",$2+1,$3,".",".",".","."}' > $1.c.${minCopies}.merged.final.gff
rm $sorted

bedtools maskfasta -fi $genome -bed $1.c.${minCopies}.merged.final.gff -fo genome.fasta.combined.masking -soft


unionMasked=$(/storage3/EukSpecies/bin/soft_fasta_to_3 < genome.fasta.combined.masking | awk -v soft_mask=$soft_mask 'BEGIN{sum=0} {if ($3-$2 > soft_mask) sum += $3-$2} END{print sum}')
originalMasked=$(/storage3/EukSpecies/bin/soft_fasta_to_3 < $genome | awk -v soft_mask=$soft_mask 'BEGIN{sum=0} {if ($3-$2 > soft_mask) sum += $3-$2} END{print sum}')

echo "$title"
echo "Masked regions (longer than $soft_mask)"
printf "Original masking: %d (%.2f Mb)\n" $originalMasked "$(bc -l <<< $originalMasked/1000000)"
printf "Combined masking (trf + original): %d (%.2f Mb)\n" $unionMasked "$(bc -l <<< $unionMasked/1000000)"
printf "Difference: %d (%.2f Mb)\n" "$(bc <<< $unionMasked-$originalMasked)" "$(bc -l <<< "($unionMasked-$originalMasked)/1000000")"


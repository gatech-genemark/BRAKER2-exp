#!/usr/bin/env gnuplot
#
# Tomas Bruna
#
# Visualize BRAKER2 results (exon and gene level) on different
# taxonomical distance as a scatter plot

set title species
set datafile separator ','
set key outside bottom center
set key spacing 1.5
unset key
set xlabel "Specificity"
set ylabel "Sensitivity"


set mxtics 2
set mytics 2

set grid xtics ytics mxtics mytics lt 0 lw 1, lt rgb "#bbbbbb" lw 1


set term pdf
set style data lp

set output type.".pdf"

set size ratio -1

set xrange [x1:x2]
set yrange [y1:y2]

# Colors: http://colorbrewer2.org/#type=qualitative&scheme=Set1&n=7

speciesColor = "#e41a1c"
subgenusColor = "#a65628"
genusColor = "#377eb8"
familyColor = "#4daf4a"
orderColor = "#984ea3"
phylumColor = "#ff7100"

pointWidth = 3
pointSize = 1

plot "es.".type.".acc" using 2:1 title "ES" w p pt 12 lw pointWidth ps pointSize lt rgb "black", \
     "braker1.".type.".acc" using 2:1 title "BRAKER1" w p pt 1 lw pointWidth ps pointSize + 0.2 lt rgb "black", \
     "phylum_excluded.".type.".acc" using 2:1 title "phylum excluded" w p pt 1 lw pointWidth ps pointSize + 0.2 lt rgb phylumColor, \
     "order_excluded.".type.".acc" using 2:1 title "order excluded" w p pt 10 lw pointWidth ps pointSize lt rgb orderColor, \
     "family_excluded.".type.".acc" using 2:1 title "family excluded" w p pt 6 lw pointWidth ps pointSize -0.05 lt rgb familyColor, \
     "genus_excluded.".type.".acc" using 2:1  title "genus excluded" w p pt 4 lw pointWidth ps pointSize - 0.1 lt rgb genusColor, \
     "subgenus_excluded.".type.".acc" using 2:1 title "subgenus excluded" w p pt 8 lw pointWidth ps pointSize lt rgb subgenusColor, \
     "species_excluded.".type.".acc" using 2:1  title "species excluded" w p pt 2 lw pointWidth ps pointSize lt rgb speciesColor


#!/usr/bin/env gnuplot
#
# Tomas Bruna
#
# Visualize Sn-Sp with respect to the maximum
# number of training genes

set datafile separator '\t' 
set key above vertical maxrows 3
set key autotitle columnhead
set key inside bottom right
set xlabel "Training genes"
set ylabel "Accuracy"

set mxtics 2
set mytics 2
set grid xtics ytics mxtics mytics lt 0 lw 1, lt rgb "#bbbbbb" lw 1

set term pdf
set style data lp

ptype=7
psize=0.5

c1 = "#a65628"
c2 = "#377eb8"

set style line 1 pt ptype ps psize lt rgb c1 lw 2
set style line 2 pt ptype ps psize lt rgb c2 lw 2

set output in.".pdf"
# set yrange [*:*]

plot in using 1:3 with linespoints ls 2, \
     in using 1:2 with linespoints ls 1


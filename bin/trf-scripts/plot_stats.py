#!/usr/bin/env python
# ==============================================================
# Tomas Bruna
# Copyright 2020, Georgia Institute of Technology, USA
#
# Plot statistics about TRF output
# ==============================================================


import argparse
import csv
import re
import sys
import matplotlib as mpl
mpl.use('Agg')
import matplotlib.pyplot as plt


def plot(args):
    x = []
    y = []
    xLabel = ""
    yLabel = ""
    header = True

    with open(args.input) as csvfile:
        plot = csv.reader(csvfile, delimiter='\t')
        for row in plot:
            if header:
                xLabel = row[0]
                yLabel = row[1]
                header = False
                continue
            x.append(int(row[0]))

            yVal = float(row[1])

            if args.scaleY > 0:
                yVal /= args.scaleY

            y.append(yVal)

    if args.xmax != -1:
        plt.xlim(0, args.xmax)

    plt.figure(figsize=(10.00,4.8))
    plt.plot(x, y)

    ymin = min(y)
    if args.ymin:
        ymin = args.ymin

    ymax = max(y)
    if args.ymax:
       	ymax = args.ymax

    plt.ylim([ymin,ymax])

    if args.line > 0:
        plt.hlines(args.line, min(x), max(x), color="red", zorder=10,
                   label="Average GC content of the genome (" +
                   str(args.line) + "%)")

    plt.xlabel(xLabel)
    if args.yLabel:
        plt.ylabel(args.yLabel)
    else:
        plt.ylabel(yLabel)
    plt.title(args.title)

    plt.grid(linestyle='--')

    if args.line > 0:
        plt.legend(loc='lower right')
    plt.savefig(args.out)


def main():
    args = parseCmd()
    plot(args)


def parseCmd():

    parser = argparse.ArgumentParser(description='Plot statistics about TRF output')

    parser.add_argument('input', type=str,
                        help='Input file')

    parser.add_argument('out', type=str,
                        help='Output file')

    parser.add_argument('--title', type=str, default="title",
                        help='Plot title')

    parser.add_argument('--xmax', type=int, default=-1)

    parser.add_argument('--scaleY', type=float, default=-1,
                        help="Scale down Y axis by this value")

    parser.add_argument('--yLabel', type=str)

    parser.add_argument('--line', type=float, default=-1,
                        help='GC line')

    parser.add_argument('--ymin', type=float)

    parser.add_argument('--ymax', type=float)

    return parser.parse_args()


if __name__ == '__main__':
    main()

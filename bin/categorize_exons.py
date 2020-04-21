#!/usr/bin/env python
# Author: Tomas Bruna

# Categorize exons in a gtf file into initial, internal, terminal and single
# Entries need to be sorted by transcript id and by
# coordinates inside transcripts
#
# Usage: categorize_exons.py in.gtf outPrefix

import csv
import os
import sys
import re


def extractFeature(text, feature):
    regex = feature + ' "([^"]+)"'
    return re.search(regex, text).groups()[0]


def handleLast(count, singleFile, terminalFile, initialFile, prevRow):
    if count == 1:
        # Previous had only one exon - was a single exon gene
        singleFile.write('\t'.join(prevRow) + "\n")
    elif count > 1:
        # Previous had >1 exons - last was a terminal exon, or initial on negative strand
        if prevRow[6] == '+':
            terminalFile.write('\t'.join(prevRow) + "\n")
        elif prevRow[6] == '-':
            initialFile.write('\t'.join(prevRow) + "\n")
        else:
            sys.stderr.write("Warning: Unrecognized strand")


def categorizeExons(input, outPrefix):
    internalFile = open(outPrefix + ".internal", "w")
    initialFile = open(outPrefix + ".initial", "w")
    singleFile = open(outPrefix + ".single", "w")
    terminalFile = open(outPrefix + ".terminal", "w")

    with open(input) as csv_file:
        csv_reader = csv.reader(csv_file, delimiter='\t')
        prevTranscript = ""
        first = True
        prevRow = []
        count = 0
        for row in csv_reader:
            if len(row) < 9:
                continue

            if row[2] == 'CDS':
                transcript = extractFeature(row[8], 'transcript_id')
                if (prevTranscript == transcript):
                    # Same transcript, this must be at least second CDS exon
                    if (count != 1):
                        # There was more than one before, previous was internal
                        internalFile.write('\t'.join(prevRow) + "\n")
                    else:
                        # There was only one exon before, must have been initial 
                        # or terminal on negative strand
                        if prevRow[6] == '+':
                            initialFile.write('\t'.join(prevRow) + "\n")
                        elif prevRow[6] == '-':
                            terminalFile.write('\t'.join(prevRow) + "\n")
                        else:
                            sys.stderr.write("Warning: Unrecognized strand")

                    count += 1
                else:
                    # Arrived at a new gene, deal with the last exon from previous:
                    handleLast(count, singleFile, terminalFile,
                               initialFile, prevRow)
                    # Reset exon counter for the new gene
                    count = 1

                prevTranscript = transcript
                prevRow = row

        # Print last exon of the last gene
        handleLast(count, singleFile, terminalFile, initialFile, prevRow)

    internalFile.close()
    initialFile.close()
    singleFile.close()
    terminalFile.close()


def main():
    if (len(sys.argv) != 3):
        sys.stderr.write("Error: Invalid number of arguments\n")
        sys.stderr.write(
            "Usage: " + os.path.basename(__file__) + " in.gtf outputPrefix\n")
        sys.stderr.write(
            "\nGtf Entries need to be sorted by transcript id and by coordinates inside transcripts\n")
        return 1
    categorizeExons(sys.argv[1], sys.argv[2])


if __name__ == '__main__':
    main()

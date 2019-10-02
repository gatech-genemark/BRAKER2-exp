# Overview

This repository contains documentation of experiments, data and results for
BRAKER2 project.

## Folder structure

The repository is organized as follows:

    .
    ├── bin                                   # Scripts for result generation and analysis
    ├── species_1                             # A test species
    │   ├── annot                             # Annotation folder
    │   │   ├── annot.gtf                     # Processed annotation
    │   │   ├── pseudo.gff3                   # Coordinates of pseudogenic regions
    │   ├── data                              # Folder with softmasked genome
    │   ├── prothint                          # Results of ProtHint protein mapping
    │   │   ├── level_X_excluded              # Results at a certain protein exclusion level
    │   │       ├── prothint.gff              # All reported hints
    │   │       ├── prothint_augustus.gff     # All reported hints in Augustus compatible format
    │   │       ├── evidence.gff              # High-confidence hints
    │   │       ├── evidence_augustus.gff     # High-confidence hints in Augustus compatible format
    │   ├── es                                # GeneMark-ES result
    │   ├── ep                                # GeneMark-EP result
    │   │   ├── level_X_excluded              # Results at a certain protein exclusion level
    │   │       ├── train                     # Results of GeneMark-EP (without plus mode enforcement)
    │   │       ├── plus                      # Results of GeneMark-EP+ (with evidence.gff enforcement)
    │   ├── braker2                           # BRAKER2 experiments
    │   │   ├── level_X_excluded              # Experiments at a certain protein exclusion level
    ├── species_2                             # Another test species
    ├── ...
    ├── species_n                             # Another test species
    └

To initialize a folder structure for a new species, run
`bin/bin/createSpeciesFolder.sh` script. For example, _Drosophila
melanogaster_ folder can be initialized as:
    
    ./bin/createSpeciesFolder.sh Drosophila_melanogaster species family order

First argument defines species name, remaining arguments define protein
exclusion levels.
    

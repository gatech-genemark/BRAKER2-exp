# Issues related to translating proteins from annotaion

BUSCO completeness plots are generated from protein sets. To get the proteins defined by annotation, we use coordinates of annotated coding transcripts to translate genomic sequence to proteins. This is done by  `gtf2aa.pl` script in AUGUSTUS.

Due to annotation-specific issues, this approach does not always yield a valid protein product -- this makes some annotation BUSCO completeness plots look worse than they really are.

This document describes issues specific to each of the annotations.

# Solanum lycopersicum (Annotation by MAKER)

The proteins translated from annotation contain in-frame stop codons. There are **308** such proteins.

For example:

```
grep -A1 Solyc05g150153.1.1 annot_prot.fasta 
>mRNA:Solyc05g150153.1.1
MMEETEAIFF**VVKFYQL*GQIASVYKEYS*KLGVYKYSYI*VELNVLC*EESHE*AKKK*RTFSLYFLKSIWRYIHQSMDDVDIELDELELVAAAAGYHYYNCIARQPSHGSTPKGSGFLTELLSADNDVCREMLRMDKHVFHKLCNILRERAMLRDTAGVMIEEQLAIFLNIVGHNERNRVIQERYQHSGETISRHFNNVLRALKSLSREFLQLPPVSTPLQILESNRFYPYFEDCIGVIDGMRIPAHVPAKDQSRFRNRKGILTQNVLAACTLDLQFIFVYPGWEGSATDSRVLRAVLDDPDQNFPPIPEGKYYLVDTGYVNTNGFIAPFPGIRYHLPEYRGANLLPRNANELFNHRHASLRNAIQKSFDVLKTRFPILKLAPQYAFHTQRDIVIAACVIHNHIRREDKSDWLFKDIEGRYVEELPDLDDNPDPHLAFQIQEQSASALRDSITAAMWNDFINKWDEW*
```

The annotated gene does not have any special comment about this in .gff file:

```
grep Solyc05g150153.1.1 ITAG4.0_gene_models.gff
SL4.0ch05  maker_ITAG  mRNA  65043642  65047796  20  +  .  ID=mRNA:Solyc05g150153.1.1;Parent=gene:Solyc05g150153.1;Name=Solyc05g150153.1.1;Note=DDE_4 domain-containing protein (AHRD V3.3 *** A0A1Q3CXR1_CEPFO);_AED=0.32;_QI=172|0.75|0.8|1|0|0|5|68|471;_eAED=0.32
SL4.0ch05  maker_ITAG  exon  65043642  65043774  .  +  .  ID=exon:Solyc05g150153.1.1.1;Parent=mRNA:Solyc05g150153.1.1
SL4.0ch05  maker_ITAG  five_prime_UTR  65043642  65043774  .  +  .  ID=five_prime_UTR:Solyc05g150153.1.1.0;Parent=mRNA:Solyc05g150153.1.1
SL4.0ch05  maker_ITAG  five_prime_UTR  65044688  65044726  .  +  .  ID=five_prime_UTR:Solyc05g150153.1.1.1;Parent=mRNA:Solyc05g150153.1.1
SL4.0ch05  maker_ITAG  exon  65044688  65044914  .  +  .  ID=exon:Solyc05g150153.1.1.2;Parent=mRNA:Solyc05g150153.1.1
SL4.0ch05  maker_ITAG  CDS  65044727  65044914  .  +  0  ID=CDS:Solyc05g150153.1.1.1;Parent=mRNA:Solyc05g150153.1.1
SL4.0ch05  maker_ITAG  CDS  65046317  65046839  .  +  1  ID=CDS:Solyc05g150153.1.1.2;Parent=mRNA:Solyc05g150153.1.1
SL4.0ch05  maker_ITAG  exon  65046317  65046839  .  +  .  ID=exon:Solyc05g150153.1.1.3;Parent=mRNA:Solyc05g150153.1.1
SL4.0ch05  maker_ITAG  CDS  65046916  65047147  .  +  0  ID=CDS:Solyc05g150153.1.1.3;Parent=mRNA:Solyc05g150153.1.1
SL4.0ch05  maker_ITAG  exon  65046916  65047147  .  +  .  ID=exon:Solyc05g150153.1.1.4;Parent=mRNA:Solyc05g150153.1.1
SL4.0ch05  maker_ITAG  CDS  65047256  65047728  .  +  2  ID=CDS:Solyc05g150153.1.1.4;Parent=mRNA:Solyc05g150153.1.1
SL4.0ch05  maker_ITAG  exon  65047256  65047796  .  +  .  ID=exon:Solyc05g150153.1.1.5;Parent=mRNA:Solyc05g150153.1.1
SL4.0ch05  maker_ITAG  three_prime_UTR  65047729  65047796  .  +  .  ID=three_prime_UTR:Solyc05g150153.1.1.0;Parent=mRNA:Solyc05g150153.1.1
```

I downloaded proteins directly from annotation to get a set of correct proteins, from ftp://ftp.solgenomics.net/tomato_genome/annotation/ITAG4.0_release/

Surprisingly, this protein set has exactly the same problem:

```
grep -A1 Solyc05g150153.1.1 ITAG4.0_proteins.fasta
MMEETEAIFF**VVKFYQL*GQIASVYKEYS*KLGVYKYSYI*VELNVLC*EESHE*AKKK*RTFSLYFLKSIWRYIHQSMDDVDIELDELELVAAAAGYHYYNCIARQPSHGSTPKGSGFLTELLSADNDVCREMLRMDKHVFHKLCNILRERAMLRDTAGVMIEEQLAIFLNIVGHNERNRVIQERYQHSGETISRHFNNVLRALKSLSREFLQLPPVSTPLQILESNRFYPYFEDCIGVIDGMRIPAHVPAKDQSRFRNRKGILTQNVLAACTLDLQFIFVYPGWEGSATDSRVLRAVLDDPDQNFPPIPEGKYYLVDTGYVNTNGFIAPFPGIRYHLPEYRGANLLPRNANELFNHRHASLRNAIQKSFDVLKTRFPILKLAPQYAFHTQRDIVIAACVIHNHIRREDKSDWLFKDIEGRYVEELPDLDDNPDPHLAFQIQEQSASALRDSITAAMWNDFINKWDEW*
```

**Solution**: In this case, it is OK to use the invalid proteins with in-frame stop codons for comparison. The issue is not resolved in annotation.

# ENSEMBL annotations

ENSEMBL annotations contain incomplete transcripts (due to incomplete initial/terminal exons).

We were aware of this problem, and therefore we checked that initial codons of all annotated genes have a 0 phase. This was not the case for _D. rerio_ for which we downloaded correctly translated proteins directly from ENSEMBL.

However, I found out that incomplete transcripts of remaining ENSEMBL genomes (T. nigroviridis and R. prolixus) also do not necessarily start with an initial exon with 0 phase. Even though, the annotation claims the phase is 0:


```
>transcript:ENSTNIT00000013574
PTRTSSWCKLRASC*GTT*GPLVR*SDCTPTRTAR*TGQTILTGATPASSWCSRPRTSRRTSPTPRTCPARSGYLL*RAL*M*T*LRFPWRRQNSGSVNSMGLSLEDTGNQRTAYPTGRWPS*SPSETGTSTSPSSSNTSSPCCSGRGCSLPSTSSSRAGASPSTEPCCSTWASWRP*RT*SGTA*SSTMWTTSRKTTATTTAAGRCLAISLPSWTNICTFFHTTSSSGA*ADSLWSSSARLMAFPTPSGAGGGK

grep ENSTNIT00000013574 annot.gtf 
Un_random  ensembl  CDS_partial  9403004  9403124  .  +  0  gene_id "gene:ENSTNIG00000010472"; transcript_id "transcript:ENSTNIT00000013574"; cds_type "Initial"; count "1_9";
Un_random  ensembl  CDS  9404825  9404941  .  +  2  gene_id "gene:ENSTNIG00000010472"; transcript_id "transcript:ENSTNIT00000013574"; cds_type "Internal"; count "2_9";
Un_random  ensembl  CDS  9405221  9405334  .  +  2  gene_id "gene:ENSTNIG00000010472"; transcript_id "transcript:ENSTNIT00000013574"; cds_type "Internal"; count "3_9";
Un_random  ensembl  CDS  9405472  9405596  .  +  2  gene_id "gene:ENSTNIG00000010472"; transcript_id "transcript:ENSTNIT00000013574"; cds_type "Internal"; count "4_9";
Un_random  ensembl  CDS  9405663  9405779  .  +  0  gene_id "gene:ENSTNIG00000010472"; transcript_id "transcript:ENSTNIT00000013574"; cds_type "Internal"; count "5_9";
.
.
```

The numbers of frameshifted proteins with in-frame stop codons after translation from annotation are:
* T. nigroviridis: **5608** 
* R. prolixus: **1686**

To confirm that this issue is caused by incomplete transcripts only, I checked the translations of complete transcripts and none of the resulting proteins contained any in-frame stop codons.

**Solution**: Download the protein sets for these species directly from ENSEMBL. These protein sets are translated correctly.


# NCBI annotations

The species annotated by NCBI have the following numbers of in-frame stop codons after directly translating the annotated transcripts:

* B. terrestris: **244**
* P. tepidariorum: **1664**
* X. tropicalis: **138**

I was able to identify several reason for these discrepancies:


### Stop codon changes

In several cases, NCBI modifies a stop codon in the sequence to a random amino acid, to extend the protein. This is accompanied by the following note in gff annotation:

```
Note=The sequence of the model RefSeq protein was modified relative to this genomic sequence to represent the inferred CDS: substituted 1 base at 1 genomic stop codon
```

There are this many cases of this event in each species:

* B. terrestris: **83**
* P. tepidariorum: **41**
* X. tropicalis: **80**

### Actual stop codon re-assignments

Annotation of X. tropicalis contains **25** cases of stop codon reassignments to selenocysteine (in regular nuclear DNA). The note in annotation for this event is:

```
Note=UGA stop codon recoded as selenocysteine
```

### Large change to assembled sequences

NCBI changes genomic sequence of multiple genes to better match the expected protein. 

These changes are sometimes large (**1036** bases changed):

```
The sequence of the model RefSeq protein was modified relative to this genomic sequence to represent the inferred CDS: added 1036 bases not found in genome assembly.
```

And sometimes smaller, but still causing a frameshift:

```
Note: inserted 1 base in 1 codon
Note: deleted 2 bases in 1 codon
```

There are this many cases of this event in each species. 

* B. terrestris: **1356**
* P. tepidariorum: **3158**
* X. tropicalis: **122**

Not all changes lead to a frameshift/reassigned stop codon, so the number is larger than the number of proteins having stop codons in translated sequence:


**Solution**: Download the protein sets for these species directly from NCBI. These protein sets are translated correctly. 

**However, I am not sure how to deal with proteins which are predicted from a modified sequence -- is it a fair comparison when the assembly itself was changed to get a better protein?**


# Other genomes

The remaining annotations did not have any issues, translation of annotation does not contain any in-frame stop codons and directly matches the available sets of protein sequences at annotation sites.

#!/usr/bin/env nextflow
camitax_version = 'v0.1.0'
println """
 ▄████▄   ▄▄▄       ███▄ ▄███▓ ██▓▄▄▄█████▓ ▄▄▄      ▒██   ██▒
▒██▀ ▀█  ▒████▄    ▓██▒▀█▀ ██▒▓██▒▓  ██▒ ▓▒▒████▄    ▒▒ █ █ ▒░
▒▓█    ▄ ▒██  ▀█▄  ▓██    ▓██░▒██▒▒ ▓██░ ▒░▒██  ▀█▄  ░░  █   ░
▒▓▓▄ ▄██▒░██▄▄▄▄██ ▒██    ▒██ ░██░░ ▓██▓ ░ ░██▄▄▄▄██  ░ █ █ ▒
▒ ▓███▀ ░ ▓█   ▓██▒▒██▒   ░██▒░██░  ▒██▒ ░  ▓█   ▓██▒▒██▒ ▒██▒
░ ░▒ ▒  ░ ▒▒   ▓▒█░░ ▒░   ░  ░░▓    ▒ ░░    ▒▒   ▓▒█░▒▒ ░ ░▓ ░
  ░  ▒     ▒   ▒▒ ░░  ░      ░ ▒ ░    ░      ▒   ▒▒ ░░░   ░▒ ░
░          ░   ▒   ░      ░    ▒ ░  ░        ░   ▒    ░    ░
░ ░            ░  ░       ░    ░                 ░  ░ ░    ░
░                                    ${camitax_version?:''}
"""

params.i = 'input'
params.x = 'fasta'

Channel
    .fromPath("${params.i}/*.${params.x}")
    .into {
        input_genomes;
        barrnap_genomes;
        bedtools_genomes;
        prodigal_genomes
    }

input_genomes.collect().println { "Input genomes: " + it }
db = Channel.fromPath( "$baseDir/db/", type: 'dir').first()


process barrnap {
    publishDir 'data', mode: 'copy'

    input:
    file genome from barrnap_genomes

    output:
    file "${genome.baseName}.barrnap.gff" into barrnap_gff

    """
    barrnap --threads 1 ${genome} > ${genome.baseName}.barrnap.gff
    """
}


process bedtools {
    publishDir 'data', mode: 'copy'

    input:
    file genome from bedtools_genomes
    file "${genome.baseName}.barrnap.gff" from barrnap_gff

    output:
    file "${genome.baseName}.16S_rRNA.fasta" into rRNA_fasta

    """
    bedtools getfasta -fi ${genome} -bed <(grep "product=16S ribosomal RNA" ${genome.baseName}.barrnap.gff)  > ${genome.baseName}.16S_rRNA.fasta
    """
}


dada2_db = 'rdp'
process dada2 {
    publishDir 'data', mode: 'copy'

    input:
    file db
    file fasta from rRNA_fasta

    output:
    file "${fasta.baseName}.dada2.txt" into silva_lineage

    script:
    if ( dada2_db == 'silva' ) {
        dada2_train_set = "${db}/silva_nr_v132_train_set.fa.gz"
        dada2_species_assignment = "${db}/silva_species_assignment_v132.fa.gz"
    } else if ( dada2_db == 'rdp' ) {
        dada2_train_set = "${db}/rdp_train_set_16.fa.gz"
        dada2_species_assignment = "${db}/rdp_species_assignment_16.fa.gz"
    } else
        error "Invalid database for dada2 specified: ${dada2_db}"

    """
    #!/usr/bin/env Rscript

    library(dada2)
    set.seed(42)

    seqs <- paste(Biostrings::readDNAStringSet("${fasta}"))
    tt <- data.frame(Batman = "NA;NA;NA;NA;NA;NA;NA")
    try(tt <- addSpecies(assignTaxonomy(seqs, "${dada2_train_set}"), "${dada2_species_assignment}"))
    write.table(tt, "${fasta.baseName}.dada2.txt", quote=F, sep=";", row.names=F, col.names=F)
    """
}


process to_ncbi_taxonomy {
    publishDir 'data', mode: 'copy'

    input:
    file lineage from silva_lineage

    output:
    file "${lineage.baseName}.ncbi.txt" into ncbi_lineage

    """
    #!/usr/bin/env python3

    import gzip

    name_to_ncbi_id = {}
    ncbi_id_to_lineage = {}

    with gzip.open("$baseDir/db/rankedlineage.dmp.gz") as f:
        for line in f:
            line = ''.join(line.decode('utf-8').rstrip().split('\t'))
            (id, name, species, genus, family, order, class_, phylum, _, superkingdom, _) = line.split('|')
            if not superkingdom:
                superkingdom = name
            elif not phylum:
                phylum = name
            elif not class_:
                class_ = name
            elif not order:
                order = name
            elif not family:
                family = name
            elif not genus:
                genus = name
            elif not species:
                species = name
            name_to_ncbi_id[name] = id
            ncbi_id_to_lineage[id] = "{};{};{};{};{};{};{}".format(superkingdom, phylum, class_, order, family, genus, species)

    with open("${lineage}") as f:
        with open("${lineage.baseName}.ncbi.txt", 'w') as g:
            for line in f:
                line = line.rstrip()
                taxa = line.split(';')
                ncbi_id = 1
                lineage = ";;;;;;"
                if ' '.join(taxa[-2:]) in name_to_ncbi_id:
                    ncbi_id = name_to_ncbi_id[' '.join(taxa[-2:])]
                else:
                    for taxon in reversed(taxa[:-1]):
                        if taxon in name_to_ncbi_id:
                            ncbi_id = name_to_ncbi_id[taxon]
                            break;
                if ncbi_id in ncbi_id_to_lineage:
                    lineage = ncbi_id_to_lineage[ncbi_id]
                g.write("{}\\t{}\\n".format(ncbi_id, lineage))
    """
}


process prodigal {
    publishDir 'data', mode: 'copy'

    input:
    file genome from prodigal_genomes

    output:
    file "${genome.baseName}.prodigal.faa" into prodiga_faa
    file "${genome.baseName}.prodigal.fna" into prodigal_fna

    """
    prodigal -a ${genome.baseName}.prodigal.faa -d ${genome.baseName}.prodigal.fna -f gff -i ${genome} -o ${genome.baseName}.prodigal.gff
    """
}


process centrifuge {
    publishDir 'data', mode: 'copy'
    maxForks 1

    input:
    file db
    file genes from prodigal_fna

    output:
    file "${genes.baseName}.centrifuge.txt"

    script:
    centrifuge_index = "${db}/p_compressed"

    """
    centrifuge -f -x ${centrifuge_index} ${genes} > ${genes.baseName}.centrifuge.txt
    """
}

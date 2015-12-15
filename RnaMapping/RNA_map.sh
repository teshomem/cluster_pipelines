#!/bin/bash
module load anaconda
module list 
date

# sh script_test.sh -d -s -m


#-------------------------------------------------------------------------------
# Read script arguments and check if files/dirs exist

while [[ $# > 0 ]]
do
key="$1"

case $key in
    -d|--dirin)  # .fastq path
	DIRIN="$2"
	if [ ! -d "$DIRIN" ]; then
	    echo 'ERROR: Directory' $DIRIN 'Does not exist!'
	    exit 1
	fi
	shift # past argument
	;;
    -g|--genome)      # OPTIONAL: path to genome
	GENOME="$2"
	shift # past argument
	;;
    -m|--mastersheet) # file name of the mastersheet
	MASTER="$2"
	shift # past argument
	;;
    --gtf)            # OPTIONAL: path to .gtf
	GTF="$2" 
	shift # past argument
	;;
    --stranded)       # OPTIOANL: yes/no/reverse Defaults to reverse
	STRANDED="$2"
	shift
	;;
    -r|--read)        # long / short 
	READ="$2"
	shift # past argument
	;;
    --copy) 
	CPFOLDER="$2"
	shift # past argument
	;;
    --desc) 
	DESC="$2"
	shift # past argument
	;;
    --execute)        # Only used for testing; use --execute no
	EXECUTE="$2"
	shift # past argument
	;;
    --trimmer)        # OPTIONAL: cutadapt/trimmomatic
	TRIMMER="$2"
	shift # past argument
	;;
    -i|--annotattribute)        # Only used for testing; use --execute no
	ANNOTATTRIBUTE="$2"
	shift # past argument
	;;
esac
shift # past argument or value
done


#-------------------------------------------------------------------------------
echo '--------------------------------------------------------------------------'
# Default set to Genome: 
if [ -z "$GENOME" ] 
then 
    GENOME=/mnt/users/fabig/Ssa_genome/CIG_3.6v2_chrom-NCBI/STAR_index
fi

# check if Genome file exists
if [ ! -d "$GENOME" ]; then
   echo 'ERROR: File' $GENOME 'Does not exist!'
   exit 1
else 
    echo 'FOUND: File' $GENOME
fi

# Default set to GTF: 
if [ -z "$GTF" ] 
then 
    GTF=/mnt/users/fabig/Ssa_genome/CIG_3.6v2_chrom-NCBI/GTF/Salmon_3p6_Chr_070715_All.filter.gtf
fi

# check if GTF file exists
if [ ! -f "$GTF" ]; then
    echo 'ERROR: File' $GTF 'Does not exist!'
    exit 1
else 
    echo 'FOUND: File' $GTF 
fi


# Default set Stranded otion (only used for HtSeq)
if [ -z "$STRANDED" ] 
then 
    STRANDED=reverse
fi

# Default set trimmer to Cutadapt
if [ -z "$TRIMMER" ] 
then 
    TRIMMER=cutadapt
fi

# Default set htseq-count IDATTR to "gene_id" (default for Ensembl) - NCBI uses "gene"
if [ -z "$ANNOTATTRIBUTE" ] 
then 
    ANNOTATTRIBUTE=gene_id
fi



#-------------------------------------------------------------------------------
# Checks for common folder copy

COMMON=/mnt/SALMON-SEQDATA/CIGENE-DATA/GENE-EXPRESSION

if [ "$CPFOLDER" != "no" -a -n "$CPFOLDER" ]; then
    # 1st check if the folder already exists
    if [ -d $COMMON/$CPFOLDER ]; then
	echo 'ERROR! Folder: ' $COMMON/$CPFOLDER ' already exists!'
        echo 'Please pick a different name'
	exit 1
    # 2nd check for description file
    else
	if [ ! -f "$DESC" ]; then
	    echo 'ERROR: Can not find the description file!'
	    echo 'You need to provide a short description file.'
	    exit 1
	fi
    fi 
elif [ ! -z "$CPFOLDER" ]; then
    echo 'ERROR! You have to provide a folder name!'
    exit 1
elif [ "$CPFOLDER" == "no" ]; then
    echo 'Results are NOT copied to common folder'
fi


#-------------------------------------------------------------------------------
# Check line terminators in MASTER
if cat -v $MASTER | grep -q '\^M' 
then
    echo 'Converting line terminators'
    sed 's/\r/\n/g' $MASTER > sheet.tmp
    mv sheet.tmp $MASTER
else
    echo 'Line terminators seem correct'
fi

#-------------------------------------------------------------------------------
# Arguments for STAR

# Number of samples
END=$(sed '1d' $MASTER | wc -l) # skip hearder line


# Calculation: how many cores to use for STAR, max 20
CORES=$(($END * 3))
if [ $CORES -gt 20 ]
then 
    CORES=20
fi

case $READ in 
    "short")
	STAR=STAR
     ;;
    "long")
	STAR=STARlong
     ;;
    "")
	echo "-r|read: You have to specify short/long"
        exit 1
     ;;
esac



# echo all input variables
echo '++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++'
echo 'Input arguments:'
echo '-----------------------'
echo 'Location of .fastq files:'
echo $DIRIN
echo 'Genome Version:'
echo $GENOME
echo '.gtf file'
echo $GTF
echo 'STAR command:'
echo $STAR
echo 'HtSeq option stranded:'
echo $STRANDED
echo '-----------------------'
echo 'Number of samples= ' $END
echo 'FIRST sample:' $(awk ' NR=='2' { print $1 $2 $3 $4 ; }' $MASTER)
echo 'LAST sample:' $(awk ' NR=='$END+1' { print $1 $2 $3 $4 ; }' $MASTER)
echo '-----------------------'
echo 'Copy to common foder:'
echo $COMMON/$CPFOLDER
echo '++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++'

# Create the folder tree if it does not exist
mkdir -p {slurm,bash,fastq_trim,qc,star,count,mapp_summary}

#===============================================================================



#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# PART 1a: Quality trim the reads, using cutadapt (ARRAY JOB)

cat > bash/sbatch-trim.sh << EOF
#!/bin/sh
#SBATCH --ntasks=1
#SBATCH --array=1-$END
#SBATCH --job-name=TRIMMER
#SBATCH --output=slurm/trim-%A_%a.out
  
module load anaconda
module list
date
  
FILEBASE=\$(awk ' NR=='\$SLURM_ARRAY_TASK_ID+1' { print \$2 ; }' $MASTER)

R1=$DIRIN'/'\$FILEBASE'_R1_001.fastq.gz'
O1='fastq_trim/'\$FILEBASE'_R1_001.trim.fastq.gz'
R2=$DIRIN'/'\$FILEBASE'_R2_001.fastq.gz'
O2='fastq_trim/'\$FILEBASE'_R2_001.trim.fastq.gz'

#------READ1---------------------
adaptorR1=\$(awk ' NR=='\$SLURM_ARRAY_TASK_ID+1' { print \$4 ; }' $MASTER)
adaptorR1='GATCGGAAGAGCACACGTCTGAACTCCAGTCAC'\$adaptorR1'ATCTCGTATGCCGTCTTCTGCTTG'

#------READ2---------------------
adaptorR2='AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGTAGATCTCGGTGGTCGCCGTATCATT'

cutadapt -q 20 -O 8 --minimum-length 40 -a \$adaptorR1 -A \$adaptorR2 -o \$O1 -p \$O2 \$R1 \$R2

EOF

# PART 1b: Quality trim the reads, using Trimmomatic (ARRAY JOB)

cat > bash/sbatch-trimmomatic.sh << EOF
#!/bin/sh
#SBATCH --ntasks=2
#SBATCH --array=1-$END
#SBATCH --job-name=TRIMMER
#SBATCH --output=slurm/trimmomatic-%A_%a.out
  
module load anaconda trimmomatic
module list
date
  
FILEBASE=\$(awk ' NR=='\$SLURM_ARRAY_TASK_ID+1' { print \$2 ; }' $MASTER)

R1=$DIRIN'/'\$FILEBASE'_R1_001.fastq.gz'
O1='fastq_trim/'\$FILEBASE'_R1_001.trim.fastq.gz'
O1S='fastq_trim/'\$FILEBASE'_R1_001.trim.single.fastq.gz'
R2=$DIRIN'/'\$FILEBASE'_R2_001.fastq.gz'
O2='fastq_trim/'\$FILEBASE'_R2_001.trim.fastq.gz'
O2S='fastq_trim/'\$FILEBASE'_R2_001.trim.single.fastq.gz'

ADAPTERS=\$(dirname \$(which trimmomatic))/adapters/TruSeq3-PE-2.fa

trimmomatic PE -threads 2 \${R1} \${R2} \${O1} \${O1S} \${O2} \${O2S} ILLUMINACLIP:\$ADAPTERS:2:30:10:8:true LEADING:3 SLIDINGWINDOW:20:20 MINLEN:40

EOF

#-------------------------------------------------------------------------------
# PART 2: Quality control (ARRAY JOB)

cat > bash/sbatch-qc.sh << EOF
#!/bin/sh
#SBATCH --ntasks=1
#SBATCH --array=1-$END
#SBATCH --job-name=QC
#SBATCH --output=slurm/qc-%A_%a.out
  
module load fastqc
module list
date
  
FILEBASE=\$(awk ' NR=='\$SLURM_ARRAY_TASK_ID+1' { print \$2 ; }' $MASTER)

R1='fastq_trim/'\$FILEBASE'_R1_001.trim.fastq.gz'
R2='fastq_trim/'\$FILEBASE'_R2_001.trim.fastq.gz'

fastqc -o qc \$R1
fastqc -o qc \$R2

EOF

#-------------------------------------------------------------------------------
# PART 4: STAR (LOOP)

cat > bash/sbatch-star.sh << EOF
#!/bin/bash
#SBATCH --job-name=STAR
#SBATCH -n $CORES
#SBATCH -N 1
#SBATCH --output=slurm/star-%j.out
    

module load star
module list
date

for TASK in {1..$END}
do

SAMPLE=\$(awk ' NR=='\$TASK+1' { print \$1 ; }' $MASTER)
FILEBASE=\$(awk ' NR=='\$TASK+1' { print \$2 ; }' $MASTER)

R1='fastq_trim/'\$FILEBASE'_R1_001.trim.fastq.gz'
R2='fastq_trim/'\$FILEBASE'_R2_001.trim.fastq.gz'

OUT=star/\$FILEBASE

$STAR --limitGenomeGenerateRAM 62000000000 \
--genomeDir $GENOME \
--readFilesCommand zcat \
--readFilesIn \$R1 \$R2 \
--outFileNamePrefix \$OUT \
--outSAMmode Full \
--outSAMtype BAM SortedByCoordinate \
--runThreadN $CORES \
--readMatesLengthsIn NotEqual \
--outSAMattrRGline ID:\$FILEBASE PL:illumina LB:\$SAMPLE SM:\$SAMPLE

echo "FILE --> " \$OUT " PROCESSED"
 
done

EOF

#-------------------------------------------------------------------------------
# PART 5: HTSeq (ARRAY JOB)

cat > bash/sbatch-htseq.sh << EOF
#!/bin/sh
#SBATCH -n 1     
#SBATCH --array=1-$END       
#SBATCH --job-name=HTseq  
#SBATCH --output=slurm/HTSeq-%A_%a.out

module load samtools anaconda
module list
date

FILEBASE=\$(awk ' NR=='\$SLURM_ARRAY_TASK_ID+1' { print \$2 ; }' $MASTER)
INC=star/\$FILEBASE'Aligned.sortedByCoord.out.bam'
INN=star/\$FILEBASE'Aligned.sortedByName.out.bam'
OUT=count/\$FILEBASE'.count'

samtools sort -n -o \$INN -T \$INN'.temp' -O bam \$INC
samtools view \$INN | htseq-count -i $ANNOTATTRIBUTE -q -s $STRANDED - $GTF > \$OUT

echo \$OUT "FINISHED"
EOF

#-------------------------------------------------------------------------------
# PART 6: STAR quality control

cat > bash/sbatch-star-check.sh << EOF
#!/bin/bash
#SBATCH --job-name=STARstat
#SBATCH -n 1
#SBATCH --output=slurm/slurm-star-stats%j.out

module load R
module list
date

cd star
R CMD BATCH /mnt/users/fabig/cluster_pipelines/RnaMapping/helper_scripts/STAR_Log.R
cd ..

EOF

#-------------------------------------------------------------------------------
# PART 7: HTSeq quality control

cat > bash/sbatch-htseq-check.sh << EOF
#!/bin/bash
#SBATCH --job-name=HTstat
#SBATCH -n 1
#SBATCH --output=slurm/slurm-htseq-stats-%j.out

module load R
module list
date

cd count
R CMD BATCH /mnt/users/fabig/cluster_pipelines/RnaMapping/helper_scripts/HTseq_plot.R
cd ..

EOF

#-------------------------------------------------------------------------------
# PART 8: COPY results to common dierectory

cat > bash/sbatch-copy.sh << EOF
#!/bin/bash
#SBATCH --job-name=copy
#SBATCH -n 1
#SBATCH --output=slurm/slurm-copy-%j.out

module list
date

mkdir $COMMON/$CPFOLDER/counts
mkdir $COMMON/$CPFOLDER/mapp_summary

cp counts/* $COMMON/$CPFOLDER/counts/
cp mapp_summary/* $COMMON/$CPFOLDER/mapp_summary/
cp $MASTER $COMMON/$CPFOLDER/
cp $DESC $COMMON/$CPFOLDER/

EOF


#===============================================================================
#===============================================================================
# SUBMIT JOBS TO SLURM


if [ "$EXECUTE" != "no" ] 
then

    #-------------------------------------------------------------------------------
    # run sbatch file
	
    if [ "$TRIMMER" == "cutadapt" ]
    then
 	command="sbatch bash/sbatch-trim.sh"
    else
	   command="sbatch bash/sbatch-trimmomatic.sh"
    fi
    TrimJob=$($command | awk ' { print $4 }')
    for i in $(seq 1 $END)
    do 
	job=$TrimJob'_'$i
	if [ -z $TrimJobArray ] 
	then 
	    TrimJobArray=$job
	else 
	    TrimJobArray=$TrimJobArray':'$job
	fi
    done
    echo '---------------'
    echo '1) sequences submitted for trimming'
    echo '   slurm ID:' $TrimJobArray

    #-------------------------------------------------------------------------------

    command="sbatch --dependency=afterok:$TrimJobArray bash/sbatch-qc.sh" # Double quotes are essential!
    QcJob=$($command | awk ' { print $4 }')
    echo '---------------'
    echo '2) Trimmed sequneces submitted for quality control'
    echo '   slurm ID' $QcJob

    #-------------------------------------------------------------------------------

    command="sbatch --dependency=afterok:$TrimJobArray bash/sbatch-star.sh"
    StarJob=$($command | awk ' { print $4 }')
    echo '---------------'
    echo '4) Trimmed sequneces submitted for mapping'
    echo '   slurm ID' $StarJob

    #-------------------------------------------------------------------------------

    command="sbatch --dependency=afterok:$StarJob bash/sbatch-htseq.sh"
    HtseqJob=$($command | awk ' { print $4 }')
    for i in $(seq 1 $END)
    do 
	job=$HtseqJob'_'$i
	if [ -z $HtseqJobArray ] 
	then 
	    HtseqJobArray=$job
	else 
	    HtseqJobArray=$HtseqJobArray':'$job
	fi
    done
    echo '---------------'
    echo '5) Mapped sequences submitted for counting'
    echo '   slurm ID' $HtseqJobArray

    #-------------------------------------------------------------------------------

    command="sbatch --dependency=afterok:$HtseqJobArray bash/sbatch-star-check.sh"
    StarStatJob=$($command | awk ' { print $4 }')
    echo '---------------'
    echo '5) Checking Star Log stats'
    echo '   slurm ID' $StarStatJob

    #-------------------------------------------------------------------------------

    command="sbatch --dependency=afterok:$HtseqJobArray bash/sbatch-htseq-check.sh"
    HtseqStatJob=$($command | awk ' { print $4 }')
    echo '---------------'
    echo '6) Checking HTSeq counting stats'
    echo '   slurm ID' $HtseqStatJob
    #-------------------------------------------------------------------------------

    # COPY files to common dierectory
    
    if [ "$CPFOLDER" != "no" -a -n "$CPFOLDER" ]; then
	command="sbatch --dependency=afterok:$HtseqJobArray bash/sbatch-copy.sh"
	CopyJob=$($command | awk ' { print $4 }')
	echo '---------------'
	echo '7) Copying file to common dierectory'
	echo '   slurm ID' $CopyJob
    fi

else
    echo '=================='
    echo 'Nothing submitted!'
    echo '=================='
fi


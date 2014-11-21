### =========================================================================
### GNCList objects
### -------------------------------------------------------------------------
###
### GNCList is a container for storing a preprocessed GenomicRanges object
### that can be used for fast findOverlaps().
###

setClass("GNCList",
    contains="GenomicRanges",
    representation(
        nclists="list",
        granges="GRanges"
    )
)


### Return the "split factor" of GenomicRanges object 'x'.
.split_factor <- function(x)
{
    #x_nseqlevels <- length(seqlevels(x))
    #levels_prefix <- rep(seq_len(x_nseqlevels), each=3L)
    #levels_suffix <- rep.int(levels(strand()), x_nseqlevels)
    #factor(paste0(as.integer(seqnames(x)), as.character(strand(x))),
    #       levels=paste0(levels_prefix, levels_suffix))
    seqnames(x)
}

.get_circle_length <- function(x)
{
    circle_length <- seqlengths(x)
    circle_length[!(isCircular(x) %in% TRUE)] <- NA_integer_
    circle_length
}


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Accessors
###

setMethod("granges", "GNCList",
    function(x, use.mcols=FALSE)
    {
        if (!isTRUEorFALSE(use.mcols))
            stop("'use.mcols' must be TRUE or FALSE")
        ans <- x@granges
        if (use.mcols)
            mcols(ans) <- mcols(x)
        ans
    }
)

setMethod("length", "GNCList", function(x) length(granges(x)))
setMethod("names", "GNCList", function(x) names(granges(x)))
setMethod("seqnames", "GNCList", function(x) seqnames(granges(x)))
setMethod("start", "GNCList", function(x, ...) start(granges(x)))
setMethod("end", "GNCList", function(x, ...) end(granges(x)))
setMethod("width", "GNCList", function(x) width(granges(x)))
setMethod("ranges", "GNCList", function(x, use.mcols=FALSE) ranges(granges(x)))
setMethod("strand", "GNCList", function(x) strand(granges(x)))
setMethod("seqinfo", "GNCList", function(x) seqinfo(granges(x)))

setAs("GNCList", "GRanges", function(from) granges(from))
setAs("GNCList", "NCLists",
    function(from)
    {
        from_granges <- granges(from)
        ans_rglist <- split(ranges(from_granges), .split_factor(from_granges))
        new2("NCLists", nclists=from@nclists, rglist=ans_rglist, check=FALSE)
    }
)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Constructor
###

GNCList <- function(x)
{
    if (!is(x, "GenomicRanges"))
        stop("'x' must be a GenomicRanges object")
    if (!is(x, "GRanges"))
        x <- as(x, "GRanges")
    mcols(x) <- NULL
    rglist <- split(ranges(x), .split_factor(x))
    nclists <- NCLists(rglist, circle.length=.get_circle_length(x))
    new2("GNCList", nclists=nclists@nclists, granges=x, check=FALSE)
}

setAs("GenomicRanges", "GNCList", function(from) GNCList(from))


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### combine_and_select_hits()
###
### A low-level (non exported) utility function for post-processing a list
### of Hits objects. Used by findOverlaps_GNCList() below and "findOverlaps"
### method for GenomicRanges objects.
###

### Rearrange the seqlevels in 'x' so that its first N seqlevels are exactly
### 'seqlevels' (in the same order).
.align_seqlevels <- function(x, seqlevels)
{
    seqlevels(x) <- union(seqlevels, seqlevels(x))
    x
}

.remap_and_combine_Hits_objects <- function(objects,
                                            q_split_factor, s_split_factor)
{
    query_len <- length(q_split_factor)
    subject_len <- length(s_split_factor)
    if (length(objects) == 0L) {
        q_hits <- s_hits <- integer(0)
    } else {
        ## Compute 'q_hits'.
        query_maps <- split(seq_len(query_len), q_split_factor)
        q_hits <-
            lapply(seq_along(objects),
                   function(i) query_maps[[i]][queryHits(objects[[i]])])
        q_hits <- unlist(q_hits)
        ## Compute 's_hits'.
        subject_maps <- split(seq_len(subject_len), s_split_factor)
        s_hits <-
            lapply(seq_along(objects),
                   function(i) subject_maps[[i]][subjectHits(objects[[i]])])
        s_hits <- unlist(s_hits)
        ## Order 'q_hits' and 's_hits'.
        oo <- S4Vectors:::orderIntegerPairs(q_hits, s_hits)
        q_hits <- q_hits[oo]
        s_hits <- s_hits[oo]
    }
    new2("Hits", queryHits=q_hits, subjectHits=s_hits,
                 queryLength=query_len, subjectLength=subject_len,
                 check=FALSE)
}

.strand_is_incompatible <- function(qh_strand, sh_strand)
{
    qh_strand == "+" & sh_strand == "-" | qh_strand == "-" & sh_strand == "+"
}

.drop_overlaps_with_incompatible_strand <- function(hits, q_strand, s_strand)
{
    qh_strand <- q_strand[queryHits(hits)]
    sh_strand <- s_strand[subjectHits(hits)]
    drop_idx <- which(.strand_is_incompatible(qh_strand, sh_strand))
    if (length(drop_idx) != 0L)
        hits <- hits[-drop_idx]
    hits
}

combine_and_select_hits <- function(list_of_Hits,
                                    q_split_factor, s_split_factor,
                                    q_strand, s_strand,
                                    select, ignore.strand)
{
    hits <- .remap_and_combine_Hits_objects(list_of_Hits,
                                            q_split_factor, s_split_factor)
    if (!ignore.strand)
        hits <- .drop_overlaps_with_incompatible_strand(hits,
                                                        q_strand, s_strand)
    selectHits(hits, select=select)
}


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### findOverlaps_GNCList()
###

### 'query.remap' and 'subject.remap' should be NA-free but we don't check
### this.
.normarg_remap <- function(query.remap, query_len, what)
{
    if (is.null(query.remap))
        return(seq_len(query_len))
    if (!(is.integer(query.remap) && length(query.remap) == query_len))
        stop("'", what, ".remap' must be NULL or an integer vector ",
             "of the length of '", what, "'")
    query.remap
}

.normarg_relength <- function(query.relength, query_len, what)
{
    if (is.null(query.relength))
        return(query_len)
    msg <- c("'", what, ".relength' must be NULL or ",
             "a single non-negative integer")
    if (!isSingleNumber(query.relength))
        stop(msg)
    if (!is.integer(query.relength))
        query.relength <- as.integer(query.relength)
    if (is.na(query.relength) || query.relength < 0L)
        stop(msg)
    query.relength
}

### NOT exported.
findOverlaps_GNCList <- function(query, subject, min.score=1L,
                                 type=c("any", "start", "end",
                                        "within", "extend", "equal"),
                                 select=c("all", "first", "last", "arbitrary"),
                                 ignore.strand=FALSE,
                                 query.remap=NULL, subject.remap=NULL,
                                 query.relength=NULL, subject.relength=NULL)
{
    if (!(is(query, "GNCList") || is(subject, "GNCList")))
        stop("'query' or 'subject' must be a GNCList object")
    if (!(is(query, "GenomicRanges") && is(subject, "GenomicRanges")))
        stop("'query' and 'subject' must be GenomicRanges objects")
    if (!isSingleNumber(min.score))
        stop("'min.score' must be a single integer")
    if (!is.integer(min.score))
        min.score <- as.integer(min.score)
    type <- match.arg(type)
    select <- match.arg(select)
    if (!isTRUEorFALSE(ignore.strand))
        stop("'ignore.strand' must be TRUE or FALSE")

    query_len <- length(query)
    subject_len <- length(subject)
    query.remap <- .normarg_remap(query.remap, query_len, "query")
    subject.remap <- .normarg_remap(subject.remap, subject_len, "subject")
    q_relen <- .normarg_relength(query.relength, query_len, "query")
    s_relen <- .normarg_relength(subject.relength, subject_len, "subject")

    if (is(subject, "GNCList")) {
       si <- merge(seqinfo(subject), seqinfo(query))
       query <- .align_seqlevels(query, seqlevels(subject))
       q_split_factor <- .split_factor(query)
       s_split_factor <- .split_factor(subject)
       q_rglist <- split(ranges(query), q_split_factor)
       s_rglist <- as(subject, "NCLists")
    } else {
       si <- merge(seqinfo(query), seqinfo(subject))
       subject <- .align_seqlevels(subject, seqlevels(query))
       q_split_factor <- .split_factor(query)
       s_split_factor <- .split_factor(subject)
       q_rglist <- as(query, "NCLists")
       s_rglist <- split(ranges(subject), s_split_factor)
    }
    circle_length <- .get_circle_length(si)
    q_remap <- split(query.remap, q_split_factor)
    s_remap <- split(subject.remap, s_split_factor)
    if (ignore.strand) {
        q_space <- s_space <- NULL
    } else {
        q_space <- split(as.integer(strand(query)) - 3L, q_split_factor)
        s_space <- split(as.integer(strand(subject)) - 3L, s_split_factor)
    }
    IRanges:::NCLists_find_overlaps_and_combine(
                           q_rglist, s_rglist, min.score,
                           type, select, circle_length,
                           q_remap, s_remap,
                           q_relen, s_relen,
                           q_space, s_space)
}

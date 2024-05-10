program packagesearch 
*! version 1.0.20  09nov2023
    version 14
    syntax , codedir(string) [  FILESave EXCELsave CSVsave NODROPfalsepos INSTALLfounds domain(string)]
	
// Options
/*
filesave = save list of parsed files

excelsave = save list of candidate packages as an excel spreadsheet

csvsave = if you want to save the CSV version of the report.

NODROPfalsepos = rm common FPs according to us 
- right now, this is: "white missing index dash title cluster pre bys" None of these are in the top 10% of package popularity at SSC 
	
installfounds = install missing package found by the match

domain = compares input files to a list of packages from domain-specific research papers (currently only "econ" is supported)

*/


***************************
* Step 1: Preliminaries   *
***************************


clear all
set more off
set maxvar 120000
local pwd : pwd

global codedir "`codedir'"

// We may need to get additional files from here
local srcref "https://aeadataeditor.github.io/Statapackagesearch/"

/* This should be generically in the PLUS directory */

local mplus : sysdir PLUS
local msub  : adosubdir "packagesearch"
local rootdir "`mplus'/`msub'"

// Common False Positives
local commonFPs "white missing index dash title cluster pre bys" 

// Additional files
local stopwords      "`rootdir'/p_stopwords.txt"
local signalcommands "`rootdir'/p_signalcommands.txt"
local domainstats    "`rootdir'/p_stats_`domain'.dta"
local pkgwords       "`rootdir'/p_keyword_pkg_xwalk.dta"
local shortwords     3
local debug          0

n di "==========================================================="
n di " Step 1 (preliminaries): Installing necessary dependencies:"

* Ensure auxiliary files are present
* import ancillary .dta if domain is selected

if ("`domain'" != "") {
	n dis "Verifying presence of auxiliary `domainstats' (domain = `domain')"
    cap confirm file "`domainstats'" 
	if _rc {
		n dis "Installing auxiliary `domainstats' (domain = `domain')"
		net get packagesearch, from(`srcref')	
	}
	else {
		dis "File `domainstats' is present."
	}
}


/* add necessary packages to perform the scan & analysis to the macro */

local ssc_packages "fs filelist txttool strip"
n di "Required packages: `ssc_packages'"

foreach pkg in `ssc_packages' {
    n di "Installing `pkg'"
    cap which `pkg'
    if (_rc==111) {
	    cap ssc install `pkg', replace
		** If error- print need to install dependencies
		if _rc==603 {
			n di as err "Packages `ssc_packages' are required, but could not be successfully installed. Please install before proceeding. "
			exit
		}
    }
}

	
/* after installing all packages, it may be necessary to issue the mata mlib index command */
qui mata: mata mlib index

di "   -> Required packages installed"

********************************************************
* Step 2: Collect list of all packages hosted at SSC   *
********************************************************

local p_vars_hot "rank hits"
if `debug' > 0 { 
	di as err "Debugging mode is on"
	di "p_vars_hot = `p_vars_hot'"
	local packagelist "packagelist.dta"
} 
else {
	tempfile packagelist
}


*import and clean ancillary .dta if econstats is selected
n di "==========================================================="
if ("`domain'" != "") {
    di as text "Using domain-specific stats from `domain'"
	qui {
		use `domainstats'
		save `packagelist'
	}
	* develop some kind of ranking system/processing similar to whatshot log
}
else {

    di as text "Step 2: Collect (and clean) list of all packages hosted at SSC"
	p_whatshot, vars(`p_vars_hot')

} // end else domain

* below should happen for both econstats and whatshot
/*
foreach v of local p_vars_hot {
	confirm numeric variable `v'
    if _rc {
        di as err "The ranking variable `v' is not numeric. Please fix something. `_rc'"
		exit 2
    }
}
*/

gen word = packagename
label var rank "Package popularity (rank out of total # of packages)"

// Develop ranking system to help determine likelihood of false positives
qui sum hits, detail

* include prob of false positive if # of monthly hits for the package is below 90th percentile
gen probFalsePos = rank/_N if _n>`r(p90)' 
replace probFalsePos = 0 if _n<=`r(p90)'
label var probFalsePos "likelihood of false positive based on package popularity"

     
sort word
	
*remove underscores from applicable packages
strip packagename, of("_") gen(p_underscore)
qui replace packagename = p_underscore
qui drop p_underscore rank
	
gsort packagename -hits
n di "Dropping duplicates pulled from SSC"
duplicates drop packagename, force
// rank by hits
gsort  -hits
gen rank = _n
sort rank
qui save "`packagelist'", replace
//if `debug' > 1 { 
	di as text "Package list generated successfully (`packagelist')"
	li in 1/10
//}


***************************
* Step 3: Parsing	      *
***************************
n di "==========================================================="
di as text "Step 3 : Parse all .do files in specified directory (split them into words)"

qui {
*Parse each .do file in a directory, then append the parsed files

* Scan files in subdirectories
	tempfile file_list 
	filelist, directory("`codedir'") pattern("*.do")
	gen temp="/"
	egen file_path = concat(dirname temp filename)
	save `file_list'
	keep file_path
	
	qui count
	local total_files = `r(N)'
	forvalues i=1/`total_files' {
		local file_`i' = file_path[`i']
	}

	* Read in each do file in the folder and split by line
	local parsedfiles ""
	forvalues i=1/`total_files' {
	    n di "file_`i'=`file_`i''"
	    local v = "`file_`i''"
	    n di "  Processing file `v'"
	    
	    infix str300 txtstring 1-300 using "`v'", clear
    
	    * indexes each line
	    gen line = _n
	    * drop blank lines
	    drop if txtstring == ""
    
    
	    *drop commented lines (drop if //, *, /* or \* appears at the start of the line)
	    drop if regexm(txtstring,"^//")==1
	    drop if regexm(txtstring,"^/\*")==1
	    drop if regexm(txtstring,"^\*")==1
    
	    /* clean - this is handled by the stopword file as well */
    
	    * split on common delimiters- txttool can't handle long strings
	    qui replace txtstring = subinstr(txtstring,"\", " ",.)
	    qui replace txtstring = subinstr(txtstring,"{", " ",.)
	    qui replace txtstring = subinstr(txtstring,"}", " ",.)
	    qui replace txtstring = subinstr(txtstring,"="," ",.)
	    qui replace txtstring = subinstr(txtstring, "$"," ",.)
	    qui replace txtstring = subinstr(txtstring, "/"," ",.)
	    qui replace txtstring = subinstr(txtstring, "_","",.)
	    qui replace txtstring = subinstr(txtstring, "*"," ",.)
	    qui replace txtstring = subinstr(txtstring, "-"," ",.)
	    qui replace txtstring = subinstr(txtstring, ","," ",.)
	    qui replace txtstring = subinstr(txtstring, "+"," ",.)
	    qui replace txtstring = subinstr(txtstring, "("," ",.)
	    qui replace txtstring = subinstr(txtstring, ")"," ",.)
	    qui replace txtstring = subinstr(txtstring, "#"," ",.)
	    qui replace txtstring = subinstr(txtstring, "~"," ",.)
	    qui replace txtstring = subinstr(txtstring, "."," ",.)
	    qui replace txtstring = subinstr(txtstring, "<"," ",.)
	    qui replace txtstring = subinstr(txtstring, ">"," ",.)
	    
	    *omit the end of lines of code (usually don't contain packages anyways)
	    qui replace txtstring = ustrleft(txtstring, 72)
	    
	    
	    * perform the txttool analysis- removes stopwords and duplicates
	    
	    cap n txttool txtstring, sub("`rootdir'/p_signalcommands.txt") stop("`rootdir'/p_stopwords.txt") gen(bagged_words)  bagwords prefix(w_)
	    	if _rc di as text "Error: file `v' contains long string unable to be processed. It has been omitted from the scanning process."
	    
	    
	    * saves the results as .dta file (one for each .do file in the folder)
	    *save "$rootdir/parsed_data_`i'.dta", replace
	    tempfile parsedfile`i'
	    save `parsedfile`i''
	    * add to list
	    local parsedfiles `parsedfiles' `parsedfile`i''
 	}
 } /* end of quiet */

**********************
* Step 4: Matching 	 *
**********************


 *List all generated .dta files and append them to prepare for the match
 
 qui{
 * == old method == 
 * fs "parsed_data*.dta"
 * cap append using `r(files)'
   tempfile completeparsed
   local firstfile ""
   foreach file in `parsedfiles' {
	   if ( "`firstfile'" == "" ) {
		   local firstfile no
		   use `file'
	   }
	   else { 
	       cap append using `file'
	   }
   }
 }
 
 if _rc ==0 {

 di as text "==========================================================="
 di as text "Step 4: Match parsed files to package list and show candidate packages"

 
*Collapses unique words into 1 observation
collapse (sum) w_* 

* create a new var and count to capture frequency
qui gen word = ""
qui gen count = 0

*expand dataset again
global counter 0
foreach var of varlist w_* {
	/* add a row for the next variable */
	global counter = $counter +1
	qui set obs $counter
	/* capture word and its count */
    
	*capture the name of the variable and its frequency and do this for every variable, then drop all variables (collapses the unique variables)
	qui replace word = "`var'" if _n == $counter
	qui replace count = `var'  if _n == $counter
}
replace word = subinstr(word,"w_","",.)
drop w_*

sort word

}
else {
 	di as text "No Stata .do files found in this directory. Please specify another location."
	exit
}

// Merge/match
rename word keyword
sort keyword
if `debug' == 1 { 
	desc
}
// Merge on word-to-package mapping

qui merge 1:1 keyword using `pkgwords', keep(match) nogen
// Drop words that are too short
di as text "::: Dropping words that are too short (<`shortwords')"
drop if length(keyword)<`shortwords'
if `debug' == 1 { 
	desc
}
// Merge on package list
di as text "::: Merging on package stats"
rename package packagename
sort packagename
if `debug' == 1 { 
	di "`packagelist'" 
	preserve
	use `packagelist', clear
	desc
	duplicates report packagename
	duplicates list packagename 
	restore
}
// desc using `packagelist'
qui merge m:1 packagename using `packagelist', keep(match) nogen
qui sum rank
local success = `r(N)'
di as text "::: Number of matched packages: `success'"


 // If no matched packages found, output message and exit
if `success' == 0 {
	di as text "No matched packages found"
	
	qui drop success success1 success2
	exit
}

// Otherwise keep going
qui{
	gen match = packagename 
	label var match "Candidate package found"
	keep if match !=""
}
di as text "Note: Underscores in package names are omitted (if applicable)"
if ("`nodropfalsepos'"== "nodropfalsepos") {
	* rm common FPs according to us
	di as err "Keeping common false positives (`commonFPs')"
}
else {
	di as text "Dropping common false positives (`commonFPs')"
	foreach word in `commonFPs' {
		qui drop if match == "`word'" 
		*replace success = success - *number of observations deleted in the for loop above*
	}

	if `success' == 0 {
		di as text "All matched packages found were false positives"
		exit
	}
}

* the list can be long, so we rely on gsort for fast sorting
di as text "==========================================================="
di as text "Candidate packages listed below:"

gsort rank match
list match rank probFalsePos keyword, ab(25) 
	
* if list is empty (only packages found were common FPs), di error message

preserve
if ("`filesave'"== "filesave") { 
   	* display list of parsed files with match results
	di "Programs parsed:"	
	use `file_list', clear
	list dirname filename, table div
}
restore


**************************************************************************
* Step 5: Export output & install found missing packages (if desired) 	 *
**************************************************************************
preserve

qui sum rank

// dis "Found `r(N)' rows."

if `r(N)' > 0 {
	if ("`excelsave'"== "excelsave" | "`csvsave'" == "csvsave" ) {
		di as text "Optional Step 5: Export results of the match (candidate packages)"

		global reportfile "`codedir'/candidatepackages.xlsx"
		global reportcsv  "`codedir'/candidatepackages.csv"

		// Set up output export
		gen confirmed_is_used = .

		// Sort by rank (incorporates false positive probability) from packagelist file
		if ("`filesave'" != "filesave") {
			gsort rank match
		}
		if ("`excelsave'"== "excelsave")  {
			// Export missing package list to Excel
			export excel match rank probFalsePos confirmed_is_used using "$reportfile", firstrow(varlabels) keepcellfmt replace sheet("Missing packages")
			di "Missing package list exported to Excel file $reportfile "	
		}
		if ("`csvsave'" == "csvsave" ) {
			// Export missing package list to Excel
			export delimited match rank  probFalsePos confirmed_is_used using "$reportcsv", replace
			di "Missing package list exported to CSV file $reportcsv "	
		}
	* export file list to report
		if ("`filesave'"== "filesave") {
			use `file_list', clear
			export excel dirname filename using "$reportfile", firstrow(varlabels) keepcellfmt sheet("Programs parsed", modify)
			di "Complete filelist exported to Excel file $reportfile "	
		}
		
	}

	restore	
		
	qui{
		if ("`installfounds'"== "installfounds") {
			n di as text "Installing packages found during the scanning process."
			* Install all found packages (including FPs)
			levelsof match, clean local(foundpackages)
			if !missing("foundpackages") {
				foreach pkg in `foundpackages' {
					n dis "Installing `pkg'"
					ssc install `pkg', replace
				}
			} 
			n di "All packages found during the scan successfully installed"	
		}
	}
}

end

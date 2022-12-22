#! /bin/bash

# This script is meant to exchange any foreign currency included in PayPal CSV statement into GBP,
# unless the foreign currency is not listed in HMRC monthly rates exchange tables

# There are exchange rates provided by HMRC used for the currencies exchange 
# https://www.gov.uk/government/collections/exchange-rates-for-customs-and-vat#monthly-rates

SCRIPT_PATH=$(dirname $(realpath $0))    # full path to the directory where the script is located
#SCRIPT_CONFIG_FILE="${SCRIPT_PATH}/config/script_config.json"   # it is not implemented yet
USER_CONFIG_FILE="${SCRIPT_PATH}/config/user_config.json"   # all script parameters are stored there, 
                                                            # like locations of PayPal and HMRC files, file naming
                                                            # conventions etc. 
JSON_ERROR_LOG="${SCRIPT_PATH}/jq_error.log"    # it is for debugging purposes, e.g. when the data are  incorrectly 
                                                # formatted in $USER_CONFIG_FLE 


function load_scripts_lib() {
    # It checks whether this library (bash-scripts-lib.sh) is present; if not, the script is quitted.
    if [ -f $SCRIPT_PATH/bash-scripts-lib.sh ]
    then
        source $SCRIPT_PATH/bash-scripts-lib.sh
    else
        echo -e "\n Critical !!! 'bash-script-lib.sh' is missing. Download it from 'https://github.com/Yannek-JS/bash-scripts-lib' into directory where this script is located.\n"
        exit 96
    fi
}


function preconfig() {
    # This function reads data from a json scritp config file, and does some pre-checking for it
    clear
    if [ -f $USER_CONFIG_FILE ]
    then
        userConfig=$(<$USER_CONFIG_FILE)    # reads user config file 
        jq -er '.' <<< $userConfig > /dev/null 2>${JSON_ERROR_LOG}  # does a syntax/format checking
        if ! [ $? -eq 0 ]
        then
            echo -e "${ORANGE}ERROR ! Config file ${BLUE} $USER_CONFIG_FILE ${ORANGE} is incorrectly formatted."
            echo -e "See ${BLUE} ${JSON_ERROR_LOG} ${ORANGE} for more details.${SC}\n"
            quit_now
        else
            # Reads and formats the user config parameters.
            # Note that the white spaces cannot be used, and they are removed. I cannot recall what was 
            # the original reason for that :-D . Possibly, it is because some parameters are being processed 
            # in arrays, what may lead to some issues when white spaces are used.
            ppDir=$(echo $userConfig | jq ".paypal_csv.dir" | sed 's/[\"\ ]//g')
            ppDirRecursively=$(echo $userConfig | jq ".paypal_csv.explore_recursively" | sed 's/[\"\ ]//g')
            ppFilenamePattern=$(echo $userConfig | jq ".paypal_csv.filename_pattern" | sed 's/[\"\ ]//g')
            hmrcDir=$(echo $userConfig | jq ".hmrc_csv.dir" | sed 's/[\"\ ]//g')
            hmrcDirRecursively=$(echo $userConfig | jq ".hmrc_csv.explore_recursively" | sed 's/[\"\ ]//g')
            hmrcFilenamePattern=$(echo $userConfig | jq ".hmrc_csv.filename_pattern" | sed 's/[\"\ ]//g')
            hmrcFilenameDateFormat=$(echo $hmrcFilenamePattern | gawk --field-separator '>>' '{print $2}' | gawk --field-separator '<<' '{print $1}')
            outputDir=$(echo $userConfig | jq ".output_csv.dir" | sed 's/[\"\ ]//g')
            outputFilenamePrefix=$(echo $userConfig | jq ".output_csv.filename_prefix" \
                                                    | sed 's/[\"\ ]//g' \
                                                    | sed "s/>>datetime<</$(date +%F_%T | sed 's/[:\-]//g')/g")
            outputFilenameSuffix=$(echo $userConfig | jq ".output_csv.filename_suffix" \
                                                    | sed 's/[\"\ ]//g' \
                                                    | sed "s/>>datetime<</$(date +%F_%T | sed 's/[:\-]//g')/g")
            outputReplaceColumns=$(echo $userConfig | jq ".output_csv.replace_columns" | sed 's/[\"\ ]//g')
        fi
    else
        echo -e 'ERROR ! User config file cannot be found.'
        echo -e "Check if ${USER_CONFIG_FILE} file exists.\n"
        quit_now
    fi
}


function prevalidation {
    # A short validation if the directories specified in ${USER_CONFIG_FILE} exist.
    if [ "$ppDir" == '' ]
    then 
        ppDir='.'   # Ha! It is good to know that when user does not specify the directory, 
                    # the current one is used. It applies to all directories being checked within this function
    elif ! [ -d "$ppDir" ]
    then 
        echo -e "\n${RED}A directory ${ORANGE}$ppDir${RED} for PayPal CSV files does not exist !${SC}"
        quit_now
    fi
    if [ "$hmrcDir" == '' ]
    then
        hmrcDir='.'
    elif ! [ -d "$hmrcDir" ]
    then 
        echo -e "\n${RED}A directory ${ORANGE}$hmrcDir${RED} for HMRC exchange rate files does not exist !${SC}"
        quit_now
    fi
    if [ "$outputDir" == '' ]
    then
        outputDir='.'
    elif ! [ -d "$outputDir" ]
    then 
        echo -e "\n${RED}A directory ${ORANGE}$outputDir${RED} for output files does not exist !${SC}"
        quit_now
    fi
}


function find_column {
    # It returns (echoing) a column in a CSV row due to a separator and column name provided as parameters. 
    # Function parameters:
    #   $1 - a row of CSV file to process
    #   $2 - a separator to split the fields into separate lines (it will be "," for PayPal CSV)
    #   $3 - a column name
    columnCounter=0
    echo -e "$(echo $1 | sed 's/'$2'/\\n/g')" | while read line; 
    do
        columnCounter=$(( $columnCounter +1 ))
        if $(echo $line | grep --quiet --ignore-case --regexp "$3")
        then 
            echo $columnCounter
            return 69
        fi
    done
}


function get_hmrc_filename {
    # It is for finding an HMRC filename correspondingly to the date of PayPal transaction.
    # The function returns HMRC filename due to the filename pattern specified in $USER_CONFIG_FILE
    # Function parameters:
    #   $1 - month (format MM)
    #   $2 - year (format YYYY)
    case $hmrcFilenameDateFormat in
        'MMYY')
            echo $(echo $hmrcFilenamePattern | sed 's/>>MMYY<</'$1${2:2}'/g')
            ;;
        'YYMM')
            echo $(echo $hmrcFilenamePattern | sed 's/>>YYMM<</'${2:2}$1'/g')
            ;;
        'MMYYYY')
            echo $(echo $hmrcFilenamePattern | sed 's/>>MMYYYY<</'$1$2'/g')
            ;;
        'YYYYMM')
            echo $(echo $hmrcFilenamePattern | sed 's/>>YYYYMM<</'$2$1'/g')
            ;;
        *)
            echo 'HMRC filename date has been specified incorrectly in JSON config file.'
            exit 96
    esac
}


function check_if_number() {
    # Function checks if a parameter passed to it is a number.
    # If it is not, the function returns 0, otherwise it returns back a parameter's value.
    # If there is not any parameter passed to the function, it is gracefully treated (exit code 69), and 0 is 
    # returned.
    if [ "$1" == '' ]; then echo 0; return 69; fi
    testVal=$(echo $1 | sed 's/,//g')   # removes a thousand comma
    if [ $(echo "testVal" | bc 2>/dev/null) ]
    then
        echo 0
    else
        echo $testVal
    fi
}


function exchange_currency {
    # It does the main job. 
    if $(echo $ppDirRecursively | grep --quiet --ignore-case --word-regexp 'true')
    # It sets up '-maxdepth' parameter for find command
    then ppMaxFindDepth=''
    else ppMaxFindDepth='-maxdepth 1'
    fi
    # It finds and process PayPal files in a directory and with a depth specified in $USER_CONFIG_FILE,
    # due to a filename pattern taken from the same config file.
    find $ppDir $ppMaxFindDepth -type f -iname "$ppFilenamePattern" | while [ $? -eq 0 ] && read ppFile;
    do
        echo -e -n "\nProcessing $ppFile file..."
        if $(echo $@ | grep --quiet --ignore-case --word-regexp '\-\-verbose'); then echo -e '\n\n'; fi
        ppCurrencyCol=0
        ppLineNo=0
        hmrcExchangeRate=1  # it is also used to check if the line may be put unmodified in an output file
        cat "$ppFile" | while read ppLine
        do
            ppLineNo=$(( $ppLineNo + 1 ))
            if [ $ppCurrencyCol -eq 0 ] && $(echo $ppLine | grep --quiet --ignore-case --regexp 'currency')
            then
                # Firstly, the column numbers for the following values need to be found in PayPal CSV file
                # 1. Currency symbol, 2. Gross value, 3. Fee, 4. Net value, 5. Transaction date.
                ppCurrencyCol=$(find_column "$ppLine" '","' 'currency')
                ppGrossCol=$(find_column "$ppLine" '","' 'gross')
                ppFeeCol=$(find_column "$ppLine" '","' 'fee')
                ppNetCol=$(find_column "$ppLine" '","' 'net')
                ppOnDateCol=$(find_column "$ppLine" '","' '"Date')
            else
                # Three lines below get the values for exchange to GBP. Comma for formatting the thousands
                # is removed to perform calculation with bc.
                ppGross=$(check_if_number $(echo $ppLine | gawk --field-separator '","' '{print $'$ppGrossCol'}'))
                ppFee=$(check_if_number $(echo $ppLine | gawk --field-separator '","' '{print $'$ppFeeCol'}'))
                ppNet=$(check_if_number $(echo $ppLine | gawk --field-separator '","' '{print $'$ppNetCol'}'))
                # Then it is checked if the values are specified in any foreigh currency (not GBP).
                if $(echo $ppLine | gawk --field-separator '","' '{print $'$ppCurrencyCol'}' | grep --quiet --invert-match --regexp 'GBP')
                then
                    # Next three lines get a foreign currency code, transaction month, and transaction year.
                    ppCurrencyCode=$(echo $ppLine | gawk --field-separator '","' '{print $'$ppCurrencyCol'}')
                    ppOnMonth=$(echo $ppLine | gawk --field-separator '","' '{print $'$ppOnDateCol'}' | gawk --field-separator '/' '{print $2}') 
                    ppOnYear=$(echo $ppLine | gawk --field-separator '","' '{print $'$ppOnDateCol'}' | gawk --field-separator '/' '{print $3}') 
                    # It sets up '-maxdepth' parameter for find command due to the $USER_CONFIG_FILE setting.
                    if $(echo $hmrcDirRecursively | grep --quiet --ignore-case --word-regexp 'true')
                    then hmrcMaxFindDepth=''
                    else hmrcMaxFindDepth='-maxdepth 1'
                    fi
                    # $hmrcFoundFiles is an array containing the HMRC files found for PayPal transction date, and 
                    # due to the settings in $USER_CONFIG_FILE: directory, file name pattern, and recursive searching. 
                    # The first [0] HMRC file in the array is used for currency exchange.
#                    echo 'on month: '$ppOnMonth'    on year: '$ppOnYear
                    hmrcFoundFiles=($(find "$hmrcDir" $hmrcMaxFindDepth -type f -name $(get_hmrc_filename $ppOnMonth $ppOnYear)))
                    if [ ${#hmrcFoundFiles[@]} -gt 0 ]
                    then
                        wsSubst='<ws>'    # The white space substitute for HMRC CSV file to process it easily with 
                                            #'for' loop
                        hmrcCurrencyCol=0
#                        echo 'file: '${hmrcFoundFiles[0]}
                        # HMRC exchange rates file is being processed... 
                        for hmrcLine in $(cat "${hmrcFoundFiles[0]}" | sed "s/ /$wsSubst/g")
                        do
                            if [ $hmrcCurrencyCol -eq 0 ] && $(echo $hmrcLine | grep --quiet --ignore-case --regexp 'currency.*code')
                            then
                                # Firstly, it finds the numbers of the columns that contain a currency code 
                                # (it was named country code in 2019), and an exchange rate.
                                hmrcCurrencyCol=$(find_column "$hmrcLine" ',' 'c[ou].*[cr]y.*code')
                                hmrcExchangeRateCol=$(find_column "$hmrcLine" ',' 'currency.*units.*per')
                            elif $(echo $hmrcLine | gawk --field-separator ',' '{print $'$hmrcCurrencyCol'}' | grep --quiet --regexp "$ppCurrencyCode")
                            then
                                # If the currently processed HMRC row match the PayPal transaction currency, then 
                                # the exchange is done
                                hmrcExchangeRate=$(echo $hmrcLine | gawk --field-separator ',' '{print $'$hmrcExchangeRateCol'}')
                                grossGBP=$(printf "%.2f" $(echo 'scale=4; '$ppGross' / '$hmrcExchangeRate | bc))
                                feeGBP=$(printf "%.2f" $(echo 'scale=4; '$ppFee' / '$hmrcExchangeRate | bc))
                                netGBP=$(echo $grossGBP' + '$feeGBP | bc)
                                # Verbose output to stdout when --verbose parameter was passed during script
                                # invocation.
                                if $(echo $@ | grep --quiet --ignore-case --word-regexp '\-\-verbose')
                                then
                                    echo "File: $ppFile, line: $ppLineNo"
                                    echo 'Date: '$(echo $ppLine | gawk --field-separator '","' '{print $'$ppOnDateCol'}' | sed 's/"//g')
                                    echo 'HMRC exchange rates file: '${hmrcFoundFiles[0]}
                                    echo "Gross ($ppCurrencyCode): $ppGross, Rate: $hmrcExchangeRate, Gross(GBP): $grossGBP"
                                    echo "Fee ($ppCurrencyCode): $ppFee, Rate: $hmrcExchangeRate, Fee(GBP): $feeGBP"
                                    echo "Net ($ppCurrencyCode): $ppNet; Net(GBP) = Gross(GBP) + Fee(GBP); Net(GBP): $netGBP"
                                    echo
                                else
                                    echo -e -n '.'  # as a progress indicator, a dot is displayed, when --verbose 
                                                    # parameter has not been used.
                                fi
                                break;  # As a row for PayPal currency has been found in HMRC file, the file
                                        # processing is stopped.
                            fi
                        done
                    else
                        # When HMRC exchange rates file has not been found for the PP transaction, the 
                        # error message is displayed, output file is being tried to remove, and a current 
                        # pipeline is quitted.
                        # 
                        echo -e "\n\nError ! An HMRC exchange rates file for $ppOnMonth/$ppOnYear was not found. Quitting the script !\n"
                        # It tries to remove $outputFile if it is being created
                        if $(echo $@ | grep --quiet --ignore-case --invert-match --word-regexp '\-\-no-output-file') \
                            && [ -f "$outputFile" ]
                        then
                            echo -e -n "Trying to remove an output file $outputFile ....."
                            rm "$outputFile"
                            if [ -f "$outputFile" ]
                            then
                                echo -e 'failed \nYou need to remove it manually !'
                            else
                                echo 'done'
                            fi
                        fi
                        exit 96
                    fi
                else
                    # If a PayPal currency is GBP in currently processed row.
                    hmrcExchangeRate=1
                    grossGBP=$ppGross
                    feeGBP=$ppFee
                    netGBP=$ppNet
                fi
            fi
            # An output CSV file is created, unless --no-output-file parameter is passed
            if $(echo $@ | grep --quiet --ignore-case --invert-match --word-regexp '\-\-no-output-file')
            then
                outputFile=$outputDir'/'${outputFilenamePrefix}$(echo $ppFile | gawk --field-separator '/' '{print $NF}')${outputFilenameSuffix}
                # $firstPart is the part of the $ppLine from the begining up to the column before $ppCurrencyCol
                # $secondPart is the part of the $ppLine from the column after $ppNetCol up to the end of line
                secondPart=$(echo $ppLine | gawk --field-separator '","' '{for(f='$(( $ppNetCol + 1 ))';f<=NF;++f)print $f "\",\""}' ORS='')
                if [ "$outputReplaceColumns" == 'false' ]
                then
                    firstPart=$(echo $ppLine | gawk --field-separator '","' '{for(f=1;f<='$ppNetCol';++f)print $f "\",\""}' ORS='')
                    if [ $ppLineNo -eq 1 ] && $(echo $ppLine | grep --quiet --ignore-case --regexp 'currency')
                    then
                        # a headline
                        echo -e $firstPart'Converted to","Exchange Rate","Gross","Fee","Net","'$(echo $secondPart | sed 's/\",\"$//g') > "$outputFile"
                    else
                        echo -e $firstPart'GBP","'$hmrcExchangeRate'","'$grossGBP'","'$feeGBP'","'$netGBP'","'$(echo $secondPart | sed 's/\",\"$//g') >> "$outputFile"
                    fi
                else
                    if [ $(echo "$hmrcExchangeRate == 1" | bc) -eq 1 ]  # An unmodified line is put in 
                                                                        # the output file then
                    then
                        echo $ppLine >> "$outputFile"
                    else
                        firstPart=$(echo $ppLine | gawk --field-separator '","' '{for(f=1;f<'$ppCurrencyCol';++f)print $f "\",\""}' ORS='')
                        # exchanged currency data is put between $firstPart and $secondPart of the $ppLine
                        echo -e $firstPart'GBP","'$grossGBP'","'$feeGBP'","'$netGBP'","'$(echo $secondPart | sed 's/\",\"$//g') >> "$outputFile"
                    fi
                fi
            fi
        done
    done
    if [ $? -eq 0 ]; then echo 'done'; fi   # That partially solves the issue around exiting functions 
                                            # and pipelines at the moment. TBC 
}


load_scripts_lib        # This script uses Yannek-JS Bash library.You can download this library 
                        # from https://github.com/Yannek-JS/bash-scripts-lib, and put it in the same directory
                        # where the script is.
preconfig               # It reads and formats the user config parameters from $USER_CONFIG_FILE
prevalidation           # It checks if the directories, specified in $USER_CONFIG_FILE, exist.
exchange_currency $@    # It passes all parameters the script has been run with. The accepted parameters are:
                        #   --verbose           - display info on the files and values that are processed
                        #   --no-output-file    - together with --verbose, it makes easier a script debugging 

#
# Actually, the better idea seems to be using a dedicated CSV parsers of other languages like Perl or Python.
# Also, lodable C compiled modules may be used in Bash, however, just the newer Bash versions support it
# https://stackoverflow.com/questions/4286469/how-to-parse-a-csv-file-in-bash
#
# On (g)awk usage for parsing CSV, you may find the following resources interesting:
#   - https://stackoverflow.com/questions/45420535/whats-the-most-robust-way-to-efficiently-parse-csv-using-awk
#   - https://stackoverflow.com/questions/4286469/how-to-parse-a-csv-file-in-bash

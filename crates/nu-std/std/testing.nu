use log.nu


# Here we store the map of annotations internal names and the annotation actually used during test creation
# The reason we do that is to allow annotations to be easily renamed without modifying rest of the code
# Functions with no annotations or with annotations not on the list are rejected during module evaluation
# test and test-skip annotations may be used multiple times throughout the module as the function names are stored in a list
# Other annotations should only be used once within a module file
# If you find yourself in need of multiple before- or after- functions it's a sign your test suite probably needs redesign
def valid-annotations [] {
    {
        "#[test]": "test",
        "#[ignore]": "test-skip",
        "#[before-each]": "before-each"
        "#[before-all]": "before-all"
        "#[after-each]": "after-each"
        "#[after-all]": "after-all"
    }
}

# Returns a table containing the list of function names together with their annotations (comments above the declaration)
#
# The way this works is we first generate an ast for a file and then extract all tokens containing keyword def with internalcall shape
# Then for each token we extract the next token (the actual function name) and the previous token (usually closing bracket of previous function)
# We then open the file as raw text and extract the last line of substring starting from the span end of previous token up to span start of the def token which contains the annotation and surrounding whitespaces
# We take the last line only in order to not pick up unrelated comments from the source code
def get-annotated [
    file: path
] {
    let raw_file = (open $file)

    let ast = (
        ^$nu.current-exe --ide-ast $file
        | from json
        | enumerate
        | flatten
    )

    $ast
    | where content == def and shape == shape_internalcall
    | insert function_name {|x|
        $ast
        | get ($x.index + 1)
        | get content
    }
    | insert annotation {|x|
        # index == 0 means the function is defined on the first lines of the file in which case there will be no preceding tokens
        if $x.index > 0 {
            let preceding_span = (
                $ast
                | get ($x.index - 1)
                | get span
            )
            $raw_file
            | str substring $preceding_span.end..$x.span.start
            | lines
            | where $it != ''
            | last
            | str trim
            | str join (char nl)
        } else {
            ''
        }
    }
    | select function_name annotation

}

# Takes table of function names and their annotations such as the one returned by get-annotated
#
# Returns a record where keys are internal names of valid annotations and values are corresponding function names
# Annotations that allow multiple functions are of type list<string>
# Other annotations are of type string
# Result gets merged with the template record so that the output shape remains consistent regardless of the table content
def create-test-record [] {
    let input = $in

    let template_record = {
        before-each: '',
        before-all: '',
        after-each: '',
        after-all: '',
        test-skip: []
    }

    let test_record = (
        $input
        | where annotation in (valid-annotations|columns)
        | update annotation {|x|
            valid-annotations
            | get $x.annotation
        }
        | group-by annotation
        | transpose key value
        | update value {|x|
            $x.value.function_name
            | if $x.key in ["test", "test-skip"] {
                $in
            } else {
                get 0
            }
        }
        | transpose -i -r -d
    )

    $template_record
    | merge $test_record

}

def throw-error [error: record] {
    error make {
        msg: $"(ansi red)($error.msg)(ansi reset)"
        label: {
            text: ($error.label)
            start: $error.span.start
            end: $error.span.end
        }
    }
}

# show a test record in a pretty way
#
# `$in` must be a `record<file: string, module: string, name: string, pass: bool>`.
#
# the output would be like
# - "<indentation> x <module> <test>" all in red if failed
# - "<indentation> s <module> <test>" all in yellow if skipped
# - "<indentation>   <module> <test>" all in green if passed
def show-pretty-test [indent: int = 4] {
    let test = $in

    [
        (" " * $indent)
        (match $test.result {
            "pass" => { ansi green },
            "skip" => { ansi yellow },
            _ => { ansi red }
        })
        (match $test.result {
            "pass" => " ",
            "skip" => "s",
            _ => { char failed }
        })
        " "
        $"($test.name) ($test.test)"
        (ansi reset)
    ] | str join
}

# Takes a test record and returns the execution result
# Test is executed via following steps:
# * Public function with random name is generated that runs specified test in try/catch block
# * Module file is opened
# * Random public function is appended to the end of the file
# * Modified file is saved under random name
# * Nu subprocess is spawned
# * Inside subprocess the modified file is imported and random function called
# * Output of the random function is serialized into nuon and returned to parent process
# * Modified file is removed
def run-test [
    test: record
] {
    let test_file_name = (random chars -l 10)
    let test_function_name = (random chars -l 10)
    let rendered_module_path = ({parent: ($test.file|path dirname), stem: $test_file_name, extension: nu}| path join)

    let test_function = $"
export def ($test_function_name) [] {
    ($test.before-each)
    try {
        $context | ($test.test)
        ($test.after-each)
    } catch { |err|
        ($test.after-each)
        $err | get raw
    }
}
"
    open $test.file
    | lines
    | append ($test_function)
    | str join (char nl)
    | save $rendered_module_path

    let result = (
        ^$nu.current-exe -c $"use ($rendered_module_path) *; ($test_function_name)|to nuon"
        | complete
    )

    rm $rendered_module_path

    return $result
}


# Takes a module record and returns a table with following columns:
#
# * file   - path to file under test
# * name   - name of the module under test
# * test   - name of specific test
# * result - test execution result
def run-tests-for-module [
    module: record<file: path name: string before-each: string after-each: string before-all: string after-all: string test: list test-skip: list>
] {
    let global_context = if not ($module.before-all|is-empty) {
            log info $"Running before-all for module ($module.name)"
            run-test {
                file: $module.file,
                before-each: 'let context = {}',
                after-each: '',
                test: $module.before-all
            }
            | if $in.exit_code == 0 {
                $in.stdout
            } else {
                throw-error {
                    msg: "Before-all failed"
                    label: "Failure in test setup"
                    span: (metadata $in | get span)
                }
            }
        } else {
            {}
    }

    # since tests are skipped based on their annotation and never actually executed we can generate their list in advance
    let skipped_tests = (
        if not ($module.test-skip|is-empty) {
            $module
            | update test $module.test-skip
            | reject test-skip
            | flatten
            | insert result 'skip'
        } else {
            []
        }
    )

    let tests = (
        $module
        | reject test-skip
        | flatten test
        | update before-each {|x|
            if not ($module.before-each|is-empty) {
                $"let context = \(($global_context)|merge \(($module.before-each)\)\)"
            } else {
                $"let context = ($global_context)"
            }
        }
        | update after-each {|x|
            if not ($module.after-each|is-empty) {
                $"$context | ($module.after-each)"
            } else {
                ''
            }
        }
        | each {|test|
            log info $"Running ($test.test) in module ($module.name)"
            log debug $"Global context is ($global_context)"

            $test|insert result {|x|
                run-test $test
                | if $in.exit_code == 0 {
                    'pass'
                } else {
                    'fail'
                }
            }
        }
        | append $skipped_tests
        | select file name test result
    )

    if not ($module.after-all|is-empty) {
        log info $"Running after-all for module ($module.name)"

        run-test {
                file: $module.file,
                before-each: $"let context = ($global_context)",
                after-each: '',
                test: $module.after-all
        }
    }
    return $tests
}

# Run tests for nushell code
#
# By default all detected tests are executed
# Test list can be filtered out by specifying either path to search for, name of the module to run tests for or specific test name
# In order for a function to be recognized as a test by the test runner it needs to be annotated with # test
# Following annotations are supported by the test runner:
# * test        - test case to be executed during test run
# * test-skip   - test case to be skipped during test run
# * before-all  - function to run at the beginning of test run. Returns a global context record that is piped into every test function
# * before-each - function to run before every test case. Returns a per-test context record that is merged with global context and piped into test functions
# * after-each  - function to run after every test case. Receives the context record just like the test cases
# * after-all   - function to run after all test cases have been executed. Receives the global context record
export def run-tests [
    --path: path,             # Path to look for tests. Default: current directory.
    --module: string,         # Test module to run. Default: all test modules found.
    --test: string,           # Individual test to run. Default: all test command found in the files.
    --exclude: string,        # Individual test to exclude. Default: no tests are excluded
    --exclude-module: string, # Test module to exclude. Default: No modules are excluded
    --list,                   # list the selected tests without running them.
] {

    let module_search_pattern = ('**' | path join ({
        stem: ($module | default "*")
        extension: nu
    } | path join))

    let path = if $path == null {
        $env.PWD
    } else {
        if not ($path | path exists) {
            throw-error {
                msg: "directory_not_found"
                label: "no such directory"
                span: (metadata $path | get span)
            }
        }
        $path
    }

    if not ($module | is-empty) {
        try { ls ($path | path join $module_search_pattern) | null } catch {
            throw-error {
                msg: "module_not_found"
                label: $"no such module in ($path)"
                span: (metadata $module | get span)
            }
        }
    }

    let modules = (
        ls ($path | path join $module_search_pattern)
        | each {|row| {file: $row.name name: ($row.name | path parse | get stem)}}
        | insert commands {|module|
            get-annotated $module.file
        }
        | filter {|x| ($x.commands|length) > 0 and ($x.commands.annotation|any {|y| $y in (valid-annotations|columns)})} # if file has no private functions at all or no functions annotated with a valid annotation we drop it
        | upsert commands {|module|
            $module.commands
            | create-test-record
        }
        | flatten
        | filter {|x| ($x.test|length) > 0}
        | filter {|x| if ($exclude_module|is-empty) {true} else {$exclude_module != $x.name}}
        | filter {|x| if ($test|is-empty) {true} else {$test in $x.test}}
        | filter {|x| if ($module|is-empty) {true} else {$module == $x.name}}
        | update test {|x|
            $x.test
            | filter {|y| if ($test|is-empty) {true} else {$y == $test}}
            | filter {|y| if ($exclude|is-empty) {true} else {$y != $exclude}}
        }
    )
    if $list {
        return $modules
    }

    if ($modules | is-empty) {
        error make --unspanned {msg: "no test to run"}
    }

    let results = (
        $modules
        | each {|module|
            run-tests-for-module $module
        }
        | flatten
    )
    if ($results | any {|x| $x.result == fail}) {
        let text = ([
            $"(ansi purple)some tests did not pass (char lparen)see complete errors below(char rparen):(ansi reset)"
            ""
            ($results | each {|test| ($test | show-pretty-test 4)} | str join "\n")
            ""
        ] | str join "\n")

        error make --unspanned { msg: $text }
    }
}
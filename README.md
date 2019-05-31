# ljtagger
Bulk tag LiveJournal entries by grepping through offline xml copy (nb: 2005 script, may no longer work)

```
Usage: ljtagger.pl [options] [file(s)]
i.e. ljtagger.pl -u user -p pass -i -e 'watch|imdb.com/' -t movies *.xml
ljtagger.pl -x

Options:
    -u --username=USERNAME  LiveJournal Username (required)
    -p --password=PASSWORD  LiveJournal Password (required)
    -e --expression=PAT     Regular Expression to match (required)
    -t --tag=TAG            LJ tag to add to matching entries (required)
    -i --ignorecase         Ignore case in pattern
    -w --whole_words        Pattern only matches whole words
    -c --configfile=FILE    Specify a config file (default ~/.ljtagger)
    -k --cookiefile=FILE    Specify a cookie file (default ~/.ljtagger_cookies)
    -x --expire_session     Expire your session cookie
    -d --debug              Debug mode (shows LJ XMLRPC server response)
    -v --verbose            Verbose mode
    -h --help               Display this help text

LJ Tagger will search your locally archived LJ contents for a pattern you
specify, and if it matches, will prompt if you want to add the specified tag to
that LJ Entry.

PAT is a Perl regular expression.  Options username, password, ignorecase,
verbose, whole-words, and cookie-file may be specified in a config file.
Config file syntax is 'option = value'.  Lines starting with a '#' and extra
whitespace are ignored.  For boolean options, set 'value' to e.g. '1' or '0'.

[file(s)] must be XML exports of your LiveJournal content.  Currently
LiveJournal's export.bml format and Logjam's 'offline copy' formats are
supported.
```

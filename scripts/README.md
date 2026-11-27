# Scripts

Miscellaneous scripts to aid in development or debugging. Organized by use case.

## design_docs

`touched_docs.py BASE MERGED` lists the `docs/design/` docs whose `Covers:` paths a PR touches;
the Lint workflow writes the list to the job summary for reviewers. `test_touched_docs.sh` is its
scenario test.

## usb

Useful for sanity checking firmware that exposes a USB interface.

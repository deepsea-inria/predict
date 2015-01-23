PROJECT_BIBS=granularity.bib

%.pdf : %.md
	pandoc $< -s -S --biblio $(PROJECT_BIBS) --toc --number-sections --highlight-style haddock -o $@

%.tex : %.md
	pandoc $< -s -S --biblio $(PROJECT_BIBS) --toc --number-sections --no-highlight -o $@

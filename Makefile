PDFLATEX = pdflatex -file-line-error -halt-on-error
LATEX = latex

#default: pstopdf
default: pdf


abstract.txt: abstract.tex
	./pull-abstract

# pldi229-chenappendix.zip : pldi229-chenappendix.pdf
#	cp -a pldi229-chenappendix.pdf pldi229-chenappendix/
#	rm pldi229-chenappendix.zip 2> /dev/null || true
#	zip -r pldi229-chenappendix.zip pldi229-chenappendix -i \*.txt \*.pdf

bib: 
	$(PDFLATEX) main
	bibtex main || true
	$(PDFLATEX) main && $(PDFLATEX) main
dvi: 
	$(LATEX) main

ps: dvi
	dvips -P pdf -o main.ps -t letter main

pstopdf: ps
	ps2pdf -dPDFSETTINGS=/printer -dEmbedAllFonts=true main.ps main.pdf

pdf: 
	$(PDFLATEX) main

final: clean bib

clean: 
	rm -f *.aux main.dvi main.bbl main.blg *.log *.out main.brf main.ps main.pdf pldi229-chen.pdf pldi229-chenappendix.pdf

# Compila o artigo. Requer TeX Live com latexmk e IEEEtran (texlive-publishers).
all: main.pdf

main.pdf: main.tex refs.bib $(wildcard sections/*.tex) $(wildcard tables/*.tex) $(wildcard figs/*.pdf)
	latexmk -pdf -interaction=nonstopmode main.tex

# Remove metadados de autor do PDF (anonimato); requer exiftool
anon: main.pdf
	exiftool -overwrite_original -all:all= main.pdf

clean:
	latexmk -C

.PHONY: all anon clean

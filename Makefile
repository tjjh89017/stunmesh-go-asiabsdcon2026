.PHONY: all clean view help

MAIN = main
PDF = $(MAIN).pdf
TEX = $(MAIN).tex

all: $(PDF)

$(PDF): $(TEX)
	latexmk -pdf -interaction=nonstopmode $(MAIN)

view: $(PDF)
	xdg-open $(PDF) 2>/dev/null || open $(PDF) 2>/dev/null || echo "Please open $(PDF) manually"

clean:
	latexmk -C
	rm -f $(MAIN).aux $(MAIN).log $(MAIN).fls $(MAIN).fdb_latexmk \
	      $(MAIN).out $(MAIN).synctex.gz missfont.log

help:
	@echo "Available targets:"
	@echo "  all    - Build the PDF (default)"
	@echo "  view   - Open the PDF"
	@echo "  clean  - Remove generated files"
	@echo "  help   - Show this help message"

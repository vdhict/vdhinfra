# Makefile — presentation artefacts
# No build step needed for decks or tour (all static HTML).
# After Hermes edits a slide: edit the HTML, reload the browser.

.PHONY: serve-long serve-short serve-tour open-long open-short open-tour screenshots check-sizes all help

LONG_DIR  := presentation/long
SHORT_DIR := presentation/short
TOUR_DIR  := tour
PORT_LONG  := 8081
PORT_SHORT := 8082
PORT_TOUR  := 8083

help:
	@echo ""
	@echo "  make serve-long    Serve long deck at http://localhost:$(PORT_LONG)"
	@echo "  make serve-short   Serve short deck at http://localhost:$(PORT_SHORT)"
	@echo "  make serve-tour    Serve scrolly tour at http://localhost:$(PORT_TOUR)"
	@echo "  make open-long     Open long deck directly in browser (no server)"
	@echo "  make open-short    Open short deck directly in browser (no server)"
	@echo "  make check-sizes   Print gzip sizes for all artefacts"
	@echo "  make all           Serve all three artefacts simultaneously"
	@echo ""

serve-long:
	@echo "Serving long deck on http://localhost:$(PORT_LONG)"
	python3 -m http.server $(PORT_LONG) --directory $(LONG_DIR)

serve-short:
	@echo "Serving short deck on http://localhost:$(PORT_SHORT)"
	python3 -m http.server $(PORT_SHORT) --directory $(SHORT_DIR)

serve-tour:
	@echo "Serving scrolly tour on http://localhost:$(PORT_TOUR)"
	python3 -m http.server $(PORT_TOUR) --directory $(TOUR_DIR)

open-long:
	open $(LONG_DIR)/index.html

open-short:
	open $(SHORT_DIR)/index.html

# Reveal.js decks need the vendor/ dir on the same path — serve from web/ root
serve-long-root:
	@echo "Serving from web/ root at http://localhost:$(PORT_LONG)/presentation/long/"
	python3 -m http.server $(PORT_LONG)

serve-short-root:
	@echo "Serving from web/ root at http://localhost:$(PORT_SHORT)/presentation/short/"
	python3 -m http.server $(PORT_SHORT)

all:
	@echo "Start three servers in separate terminals:"
	@echo "  make serve-long-root PORT_LONG=$(PORT_LONG)"
	@echo "  make serve-short     PORT_SHORT=$(PORT_SHORT)"
	@echo "  make serve-tour      PORT_TOUR=$(PORT_TOUR)"

check-sizes:
	@echo "--- Gzip sizes ---"
	@echo "Long deck:"
	@gzip -c presentation/long/index.html | wc -c | xargs -I{} echo "  index.html: {} bytes"
	@echo "Short deck:"
	@gzip -c presentation/short/index.html | wc -c | xargs -I{} echo "  index.html: {} bytes"
	@echo "Tour:"
	@gzip -c tour/index.html | wc -c | xargs -I{} echo "  index.html: {} bytes"
	@echo "Reveal.js vendor (shared):"
	@gzip -c vendor/reveal.js | wc -c | xargs -I{} echo "  reveal.js: {} bytes"
	@gzip -c vendor/reveal.css | wc -c | xargs -I{} echo "  reveal.css: {} bytes"
	@echo "Theme:"
	@gzip -c presentation/theme.css | wc -c | xargs -I{} echo "  theme.css: {} bytes"
	@echo "--"
	@echo "All output is static HTML/CSS/JS — no build step required."
	@echo "To rebuild after a content edit: edit the HTML file directly, reload the browser."

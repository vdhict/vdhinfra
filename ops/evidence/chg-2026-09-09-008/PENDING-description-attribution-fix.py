#!/usr/bin/env python3
"""
chg-2026-09-09-008 — PENDING pre-close fix. NOT APPLIED on 2026-09-09 (Atlas: nothing
further tonight, do not touch the office).

The deployed description of automation 1734200001012 attributes the 22:25 lamp-off and the
automation disable to THE USER. It was ATLAS. Verified: light.kantoor last_changed
22:25:17.220931 local carries context user_id 4832674707834e04876a87611922a62b, which is an
API call on the user's long-lived token, not a UI action by him.

Usage tomorrow (after Themis review, before close):
    python3 PENDING-description-attribution-fix.py /path/to/automations.yaml
then kubectl cp it back, homeassistant.check_config, automation.reload.
Idempotent: refuses to run twice.
"""
import sys

OLD = """    D4. DE REGELAAR OVERRULEDE OOK EEN HANDMATIGE UIT-ACTIE — ONTDEKT TIJDENS DEZE WIJZIGING,
        NIET GEMELD IN DE OPDRACHT. Waargenomen op 2026-09-09:
          22:25:17  lamp UIT (met de hand; de gebruiker zat op dat moment in het kantoor,
                    binary_sensor.kantoor_bezet stond onafgebroken 'on' sinds 21:15:41)
          ~22:29    automation.kantoor_adaptieve_verlichting werd UITGEZET
        Om 22:31 was de live toestand: bezet=on, lamp=off, ambient=0, doel=100%,
        mag_sturen=True. Met de automation aan zou de lamp bij de eerstvolgende trigger dus
        op 100% zijn gesprongen, boven op iemand die het licht net bewust had uitgedaan.
        De meest waarschijnlijke lezing is dat de gebruiker de automation daarom heeft
        uitgezet. Hard te bewijzen is dat niet: recorder.exclude bevat het hele domein
        'automation', dus er is geen historie van deze entiteit.
"""

NEW = """    D4. DE REGELAAR OVERRULEDE OOK EEN UIT-ACTIE VAN BUITENAF — ONTDEKT TIJDENS DEZE
        WIJZIGING, NIET GEMELD IN DE OPDRACHT. Waargenomen op 2026-09-09:
          22:25:13.94  automation.kantoor_adaptieve_verlichting UITGEZET   (door Atlas)
          22:25:17.22  light.kantoor UIT                                   (door Atlas, +3,3 s)
        Die volgorde was opzettelijk: eerst de automation uit, daarna het licht, zodat het
        override-defect de lamp niet meteen weer kon aandoen.

        LET OP — DE ACTOR IS NIET DE GEBRUIKER. Het uit-commando kwam van een API-client met
        het long-lived token van de gebruiker, dus in het logboek staat er zijn user_id
        (4832674707834e04876a87611922a62b) bij en is het NIET te onderscheiden van een
        handmatige druk op de knop in de UI.

        Om 22:31 was de live toestand: bezet=on, lamp=off, ambient=0, doel=100%,
        mag_sturen=True. Met de automation aan zou de lamp bij de eerstvolgende trigger dus
        op 100% zijn gesprongen, boven op een bewust gegeven uit-commando.

        JUIST DAAROM DISCRIMINEERT HET EIGENAARSCHAP HIERONDER NIET OP HA-CONTEXT OF
        user_id. Dat kan namelijk twee kanten op fout gaan:
          - een Hue-wandschakelaar of de Hue-app levert HELEMAAL GEEN HA-context, en
          - een API-client van een agent levert de context VAN DE GEBRUIKER.
        De regelaar markeert daarom zijn EIGEN commando's (vlag zetten vlak vóór zijn eigen
        light.turn_on, vlag wissen vlak vóór zijn eigen light.turn_off); al het andere is per
        definitie extern. Die toets is actor-onafhankelijk en overleeft beide gevallen.

        Het defect gold dus voor elk uit-commando van buiten de regelaar — gebruiker, Atlas,
        Node-RED of de automation 'Kantoor Einde Werkdag' — zolang de kamer bezet las.
"""

def main(path):
    s = open(path, encoding="utf-8").read()
    if NEW.split("\n")[0] in s:
        print("already applied - nothing to do"); return 0
    if s.count(OLD) != 1:
        print("REFUSING: expected exactly 1 match, found %d" % s.count(OLD)); return 1
    open(path, "w", encoding="utf-8").write(s.replace(OLD, NEW))
    print("attribution corrected in", path); return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))

#!/usr/bin/env python3
"""Write petclinic.tsv for tests/petclinic_test.d from the response bodies the real spring-petclinic-rest (Spring
Boot 4.2.0, Jackson 3.1.8) recorded in benchmarks/spring/suites/golden/petclinic-rest.json, in the compact form
springsuite compares: `case<TAB>dto<TAB>json`. Run from this directory: python3 petclinic_bodies.py"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
CASES = {
    'owner with pets and visits': 'OwnerDto',
    'list owners': 'OwnerDto[]',
    'owner pet': 'PetDto',
    'list pets': 'PetDto[]',
    'list visits': 'VisitDto[]',
    'list pet types': 'PetTypeDto[]',
    'list specialties': 'SpecialtyDto[]',
    'list vets': 'VetDto[]',
    'vet with specialties': 'VetDto',
    'v2 owners default page': 'OwnerPageDto',
    'v2 owners past the end': 'OwnerPageDto',
    'v2 pets page': 'PetPageDto',
    'create owner with UTF-8 names': 'OwnerDto',
    'create user': 'UserDto',
}
golden = json.loads((ROOT / 'benchmarks/spring/suites/golden/petclinic-rest.json').read_text())
lines = []
for observation in golden['observations']:
    if observation['name'] in CASES:
        response = observation['response']
        assert response['compact'], observation['name']
        body = json.dumps(response['json'], separators=(',', ':'), ensure_ascii=False)
        lines.append(f"{observation['name']}\t{CASES[observation['name']]}\t{body}")
# One schemaValidationErrors element (ValidationMessageDto with its @JsonAnyGetter map).
for observation in golden['observations']:
    if observation['name'] == 'create owner: telephone with letters':
        element = observation['response']['json']['schemaValidationErrors'][0]
        lines.append(f"validation message\tValidationMessageDto\t{json.dumps(element, separators=(',', ':'), ensure_ascii=False)}")
assert len(lines) == len(CASES) + 1, len(lines)
Path('petclinic.tsv').write_text('\n'.join(lines) + '\n', encoding='utf-8')

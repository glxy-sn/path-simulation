import pytest
from pydantic import ValidationError
from models import VenueInput, FloorBounds
from pipeline.bounds import clamp_world


def test_shared_bounds_clamp_edges_and_preserve_interior():
    venue=VenueInput(widthM=10,heightM=8,floorBounds=FloorBounds(left=.1,top=.2,right=.9,bottom=.8))
    assert clamp_world(-2,10,venue)==(1,6.4)
    assert clamp_world(12,-2,venue)==(9,1.6)
    assert clamp_world(4,4,venue)==(4,4)


def test_old_jobs_keep_original_coordinates():
    assert clamp_world(-1,12,VenueInput(widthM=10,heightM=8))==(-1,12)


def test_inverted_bounds_are_rejected():
    with pytest.raises(ValidationError): FloorBounds(left=.8,right=.2)

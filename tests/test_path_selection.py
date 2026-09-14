from types import SimpleNamespace
import numpy as np
from pipeline.path_selection import detail_path_groups, walking_journeys, synchronize_detail_paths

VENUE=SimpleNamespace(widthM=10,heightM=10)
def route(y=1, reverse=False):
    xs=np.linspace(1,8,36)
    if reverse: xs=xs[::-1]
    return [(float(i),float(x),y) for i,x in enumerate(xs)]

def test_frequency_and_unique_ids():
    groups=detail_path_groups({i:route() for i in range(4)},VENUE)
    assert len(groups)==1 and groups[0]['count']==4 and groups[0]['uniqueIDs']==4
    assert groups[0]['share']==1
    assert groups[0]['observations']==route()

def test_reverse_direction_is_distinct():
    groups=detail_path_groups({0:route(),1:route(),2:route(reverse=True),3:route(reverse=True)},VENUE)
    assert len(groups)==2

def test_rare_long_route_does_not_replace_common_route():
    groups=detail_path_groups({0:route(),1:route(),2:route(8)},VENUE)
    assert len(groups)==1 and groups[0]['count']==2
    assert groups[0]['share']==2/3

def test_stop_splits_two_journeys():
    first=route()
    stop=[(36+i,8,1) for i in range(8)]
    second=[(44+t,x,y) for t,x,y in route(reverse=True)]
    assert len(walking_journeys({1:first+stop+second}))==2

def test_gap_does_not_invent_journey():
    assert walking_journeys({1:[(0,0,0),(100,9,9)]})==[]

def test_synchronized_endpoints():
    tracks={1:route(),2:route(2)}
    output=synchronize_detail_paths(tracks)
    assert all(v[0][0]==0 and v[-1][0]==10 for v in output.values())

def test_ten_group_limit_and_frequency_priority():
    tracks={}
    for group in range(12):
        for repeat in range(2+group):
            tracks[len(tracks)]=route(group*2)
    selected=detail_path_groups(tracks,VENUE)
    assert len(selected)==10
    assert [g['count'] for g in selected[:7]]==list(range(13,6,-1))


def test_short_routes_are_excluded_even_if_frequent():
    short=[(float(i), 1+i*0.2, 1) for i in range(16)]
    assert walking_journeys({i:short for i in range(20)})==[]


def test_long_local_wandering_does_not_pass_span_threshold():
    points=[(float(i), (i%10)*0.2, 1) for i in range(80)]
    assert walking_journeys({1:points})==[]

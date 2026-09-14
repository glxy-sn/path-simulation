"""One shared floor boundary for all cameras, applied after identity association."""
def clamp_world(x, y, venue):
    bounds = venue.floorBounds
    if bounds is None:
        return float(x), float(y)
    return (max(bounds.left*venue.widthM, min(bounds.right*venue.widthM, float(x))),
            max(bounds.top*venue.heightM, min(bounds.bottom*venue.heightM, float(y))))

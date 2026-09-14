"""Opt-in short-term descriptor reuse for unambiguous, nearly stationary detections."""
import numpy as np


class DescriptorReuse:
    def __init__(self, interval):
        self.interval = interval
        self.boxes = np.empty((0,4),dtype=np.float32)
        self.embeddings = None
        self.times = np.empty(0)

    def features(self, model, boxes, frame, time):
        count = len(boxes)
        reuse = {}
        if self.embeddings is not None and len(self.boxes) and count:
            lo = np.maximum(boxes[:,None,:2],self.boxes[None,:,:2])
            hi = np.minimum(boxes[:,None,2:],self.boxes[None,:,2:])
            inter = np.maximum(hi-lo,0).prod(2)
            area = np.maximum(boxes[:,2:]-boxes[:,:2],0).prod(1)
            previous = np.maximum(self.boxes[:,2:]-self.boxes[:,:2],0).prod(1)
            iou = inter/np.maximum(area[:,None]+previous[None,:]-inter,1e-6)
            for row in range(count):
                col = int(iou[row].argmax())
                # Reject crowded/ambiguous candidates instead of borrowing another person's descriptor.
                if (iou[row,col] >= .9 and np.count_nonzero(iou[row] > .3)==1
                    and np.count_nonzero(iou[:,col] > .3)==1
                    and 0 <= time-self.times[col] < self.interval):
                    reuse[row] = col
        fresh = [i for i in range(count) if i not in reuse]
        calculated = np.asarray(model.get_features(boxes[fresh],frame),dtype=np.float32) if fresh else None
        width = calculated.shape[-1] if calculated is not None else self.embeddings.shape[-1]
        result = np.empty((count,width),dtype=np.float32)
        updated_times = np.full(count,time,dtype=float)
        if fresh:
            result[fresh] = calculated
        for row,col in reuse.items():
            result[row] = self.embeddings[col]
            updated_times[row] = self.times[col]
        self.boxes = boxes.copy()
        self.embeddings = result.copy()
        self.times = updated_times
        return result

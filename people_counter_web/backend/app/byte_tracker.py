import cv2
import numpy as np
from typing import List, Tuple, Optional
from dataclasses import dataclass
from bytetracker import BYTETracker
import logging

logger = logging.getLogger(__name__)

@dataclass
class TrackedPerson:
    """Класс для хранения информации о трекируемом человеке"""
    track_id: int
    bbox: Tuple[int, int, int, int]  # x1, y1, x2, y2
    confidence: float
    class_id: int
    is_inside_roi: bool = False

class ByteTrackerWrapper:
    """Обертка для ByteTrack трекера"""
    
    def __init__(self, track_thresh: float = 0.5, track_buffer: int = 30, match_thresh: float = 0.8):
        """
        Инициализация ByteTrack трекера
        
        Args:
            track_thresh: Порог уверенности для начала трекинга
            track_buffer: Размер буфера треков
            match_thresh: Порог для сопоставления треков
        """
        self.tracker = BYTETracker(
            track_thresh=track_thresh,
            track_buffer=track_buffer,
            match_thresh=match_thresh,
            frame_rate=30  # Предполагаем 30 FPS
        )
        self.tracked_persons: List[TrackedPerson] = []
        self.frame_id = 0
        
        if logger.isEnabledFor(logging.DEBUG):
            logger.debug(f"ByteTracker initialized with track_thresh={track_thresh}, track_buffer={track_buffer}, match_thresh={match_thresh}")
    
    def update(self, detections: List[Tuple[int, int, int, int, float, int]], roi_polygon: Optional[np.ndarray] = None) -> List[TrackedPerson]:
        """
        Обновление треков на основе новых детекций
        
        Args:
            detections: Список детекций в формате (x1, y1, x2, y2, confidence, class_id)
            roi_polygon: Полигон ROI для проверки нахождения внутри области
            
        Returns:
            Список трекируемых людей
        """
        if not detections:
            # Если нет детекций, обновляем трекер пустым списком
            self.tracker.update([], [], [])
            self.tracked_persons = []
            self.frame_id += 1
            return []
        
        # Преобразуем детекции в формат ByteTrack
        bboxes = []
        scores = []
        class_ids = []
        
        for x1, y1, x2, y2, conf, cls_id in detections:
            bboxes.append([x1, y1, x2, y2])
            scores.append(conf)
            class_ids.append(cls_id)
        
        bboxes = np.array(bboxes)
        scores = np.array(scores)
        class_ids = np.array(class_ids)
        
        # Обновляем трекер
        online_targets = self.tracker.update(
            scores, bboxes, class_ids
        )
        
        # Обрабатываем результаты трекинга
        self.tracked_persons = []
        
        for target in online_targets:
            tlwh = target.tlwh
            tid = target.track_id
            score = target.score
            cls_id = target.cls
            
            # Преобразуем tlwh (top-left width height) в bbox (x1, y1, x2, y2)
            x1, y1, w, h = tlwh
            x2, y2 = x1 + w, y1 + h
            
            # Проверяем, находится ли человек внутри ROI
            is_inside_roi = False
            if roi_polygon is not None:
                # Проверяем центр bounding box
                center_x = int(x1 + w // 2)
                center_y = int(y1 + h // 2)
                is_inside_roi = cv2.pointPolygonTest(roi_polygon, (center_x, center_y), False) >= 0
                
                # Если центр внутри, проверяем все углы
                if is_inside_roi:
                    corners = [
                        (int(x1), int(y1)),  # top-left
                        (int(x2), int(y1)),  # top-right
                        (int(x2), int(y2)),  # bottom-right
                        (int(x1), int(y2))   # bottom-left
                    ]
                    
                    # Человек считается полностью внутри ROI только если все углы внутри
                    is_inside_roi = all(
                        cv2.pointPolygonTest(roi_polygon, corner, False) >= 0 
                        for corner in corners
                    )
            
            tracked_person = TrackedPerson(
                track_id=tid,
                bbox=(int(x1), int(y1), int(x2), int(y2)),
                confidence=score,
                class_id=int(cls_id),
                is_inside_roi=is_inside_roi
            )
            
            self.tracked_persons.append(tracked_person)
            
            if logger.isEnabledFor(logging.DEBUG):
                logger.debug(f"Track {tid}: bbox={tracked_person.bbox}, conf={score:.3f}, inside_roi={is_inside_roi}")
        
        self.frame_id += 1
        
        if logger.isEnabledFor(logging.DEBUG):
            logger.debug(f"Frame {self.frame_id-1}: {len(self.tracked_persons)} tracked persons")
        
        return self.tracked_persons
    
    def get_tracked_persons(self) -> List[TrackedPerson]:
        """Возвращает текущий список трекируемых людей"""
        return self.tracked_persons
    
    def reset(self):
        """Сброс трекера"""
        self.tracker = BYTETracker(
            track_thresh=self.tracker.track_thresh,
            track_buffer=self.tracker.track_buffer,
            match_thresh=self.tracker.match_thresh,
            frame_rate=30
        )
        self.tracked_persons = []
        self.frame_id = 0
        
        if logger.isEnabledFor(logging.DEBUG):
            logger.debug("ByteTracker reset") 
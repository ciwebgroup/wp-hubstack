-- Clean up Action Scheduler Queue
-- Run these queries to clear stuck actions and reduce queue size

-- Delete completed actions older than 30 days
DELETE FROM wp_actionscheduler_actions 
WHERE status = 'complete' 
AND scheduled_date_gmt < DATE_SUB(NOW(), INTERVAL 30 DAY);

-- Delete failed actions older than 7 days
DELETE FROM wp_actionscheduler_actions 
WHERE status = 'failed' 
AND scheduled_date_gmt < DATE_SUB(NOW(), INTERVAL 7 DAY);

-- Cancel stuck in-progress actions (older than 1 hour)
UPDATE wp_actionscheduler_actions 
SET status = 'failed' 
WHERE status = 'in-progress' 
AND scheduled_date_gmt < DATE_SUB(NOW(), INTERVAL 1 HOUR);

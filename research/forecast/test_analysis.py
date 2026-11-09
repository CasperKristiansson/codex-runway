import unittest
from score_journal import score
from analyze import covered, quota_intervals, quota_predict, metrics, HOUR, EPOCH

class ForecastStudyChecks(unittest.TestCase):
    def test_exposure_is_union_not_sum_of_accounts(self):
        self.assertAlmostEqual(covered(0,10,[(0,8,0,0),(2,10,0,1)]),1)
        self.assertAlmostEqual(covered(0,10,[(0,2,0,0),(8,10,0,1)]),.4)

    def test_reset_delta_excluded_and_legacy_weight_inferred(self):
        snapshots=[{'capturedAt':0,'resetAt':10000,'usedPercent':10},
                   {'capturedAt':3600,'resetAt':10000,'usedPercent':20,'capacityUnits':4},
                   {'capturedAt':11000,'resetAt':20000,'usedPercent':5,'capacityUnits':4}]
        intervals,audit=quota_intervals([{'planName':'Pro 20×','snapshots':snapshots}])
        self.assertEqual(len(intervals),1)
        self.assertAlmostEqual(intervals[0][2],.4)
        self.assertEqual(audit[0]['intervals']['reset_boundary'],1)

    def test_baseline_uses_one_calendar_denominator(self):
        train=[(0,4*HOUR,1,0),(4*HOUR,8*HOUR,1,1)]
        self.assertAlmostEqual(quota_predict(train,10*HOUR,5,'app_30d'),1)

    def test_unused_window_drift_and_first_use_are_observations(self):
        week=7*24*HOUR
        def reading(t,used,reset=None):
            return {'capturedAt':t,'resetAt':reset if reset is not None else t+week-2,
                    'usedPercent':used,'capacityUnits':4,'windowDurationMins':10080}
        snapshots=[reading(0,100,HOUR),reading(2*HOUR,0),reading(3*HOUR,0),
                   reading(4*HOUR,3,4*HOUR+week-600)]
        intervals,audit=quota_intervals([{'planName':'Pro 20×','snapshots':snapshots}])
        self.assertEqual(len(intervals),2)
        self.assertEqual(audit[0]['intervals']['reset_boundary'],1)
        self.assertAlmostEqual(sum(row[2] for row in intervals),.12)
        snapshots[-1]['usedPercent']=0  # An anchored first use can still round to 0%.
        intervals,_=quota_intervals([{'planName':'Pro 20×','snapshots':snapshots}])
        self.assertEqual(len(intervals),2)
        self.assertEqual(sum(row[2] for row in intervals),0)

    def test_floating_deadlines_do_not_bridge_missing_windows_or_plan_changes(self):
        week=7*24*HOUR
        old={'capturedAt':0,'resetAt':week,'usedPercent':0,'capacityUnits':4,'windowDurationMins':10080}
        for new in [dict(old,capturedAt=week+HOUR,resetAt=2*week+HOUR),
                    dict(old,capturedAt=HOUR,resetAt=week+HOUR,capacityUnits=10),
                    dict(old,capturedAt=HOUR,resetAt=week+HOUR,windowDurationMins=300),
                    dict(old,capturedAt=HOUR,resetAt=week-120)]:
            intervals,_=quota_intervals([{'planName':'Pro 20×','snapshots':[old,new]}])
            self.assertEqual(intervals,[])

    def test_completed_endpoint_prevents_future_leak(self):
        origin=10*HOUR
        intervals=[(0,5*HOUR,1,0),(5*HOUR,20*HOUR,9,0)]
        train=[x for x in intervals if x[1]<=origin]
        self.assertAlmostEqual(quota_predict(train,origin,10,'app_30d'),1)

    def test_daily_shape_conserves_24h_demand(self):
        train=[(k*HOUR,(k+1)*HOUR,.1 if k%24>6 else .01,0) for k in range(96)]
        for origin in (96*HOUR,96.5*HOUR):
            self.assertAlmostEqual(quota_predict(train,origin,24,'circadian'),
                                   quota_predict(train,origin,24,'app_30d'))

    def test_signed_bias_and_absolute_error(self):
        m=metrics([(1,0),(1,3)])
        self.assertEqual(m['mae'],1.5);self.assertEqual(m['bias'],.5)

class JournalScoringChecks(unittest.TestCase):
    def fixture(self):
        snapshots=[{'id':str(i),'capturedAt':10000+i*HOUR,'resetAt':100000,
                    'usedPercent':i*10,'capacityUnits':1} for i in range(5)]
        accounts=[{'id':'a','planName':'Pro 5×','snapshots':snapshots}]
        record={'schemaVersion':1,'origin':10000,'accounts':[{'id':'a','capacityUnits':1,'snapshot':snapshots[0]}],
                'candidates':[{'model':'test','predictions':[{'horizonHours':3,'units':.5}]}]}
        return record,accounts

    def test_scores_only_mature_observed_targets(self):
        record,accounts=self.fixture()
        result=score([record],accounts,EPOCH+10000+4*HOUR)
        metric=result['scores_units']['test/3h']['all_origins']
        self.assertAlmostEqual(metric['mean_actual'],.3)
        self.assertAlmostEqual(metric['bias'],.2)
        pending=score([record],accounts,EPOCH+10000+2*HOUR)
        self.assertEqual(pending['scores_units'],{})
        self.assertEqual(pending['skipped']['pending_candidate_targets'],1)

    def test_missing_account_and_long_gap_are_not_zero(self):
        record,accounts=self.fixture()
        self.assertEqual(score([record],[],EPOCH+100000)['scores_units'],{})
        accounts[0]['snapshots']=accounts[0]['snapshots'][::4]
        result=score([record],accounts,EPOCH+100000)
        self.assertEqual(result['scores_units'],{})
        self.assertEqual(result['skipped']['insufficient_observation_candidate_targets'],1)

if __name__=='__main__':unittest.main()

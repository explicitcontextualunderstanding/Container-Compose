#!/usr/bin/env python3
"""
Performance Dashboard for Container-Compose Test Harness
Generates "Sustainability Scorecard" for 8GB M2 environments

Usage: python3 scripts/analyze-performance.py <test_log> <resource_csv> [--baseline baseline.json]
"""

import sys
import json
import re
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional, Tuple
import csv

# Constants for 8GB M2 optimization
MEMORY_WARNING_THRESHOLD_MB = 500
MEMORY_CRITICAL_THRESHOLD_MB = 200
IO_WAIT_WARNING_PERCENT = 50
GUARD_EFFICIENCY_WARNING_THRESHOLD = 20  # Skip > 20% of tests


class PerformanceAnalyzer:
    """Analyzes test performance and resource usage to generate scorecard"""
    
    def __init__(self, test_log_path: str, resource_csv_path: str, baseline_path: Optional[str] = None):
        self.test_log_path = Path(test_log_path)
        self.resource_csv_path = Path(resource_csv_path)
        self.baseline_path = Path(baseline_path) if baseline_path else None
        
        # Parsed data
        self.test_results: Dict = {}
        self.resource_data: List[Dict] = []
        self.baseline: Optional[Dict] = None
        
    def parse_test_log(self) -> Dict:
        """Parse Swift test output log"""
        results = {
            'total_tests': 0,
            'passed': 0,
            'failed': 0,
            'skipped': 0,
            'duration_seconds': 0,
            'memory_guard_skips': 0,
            'pool_hits': 0,
            'container_creations': 0,
            'test_suites': []
        }
        
        if not self.test_log_path.exists():
            return results
            
        content = self.test_log_path.read_text()
        
        # Parse test counts - use ✔/✘ symbols as primary source
        # Swift test output uses these symbols for individual test results
        
        # Primary: Count ✔/✘ symbols (most reliable)
        results['passed'] = len(re.findall(r'✔ Test', content))
        results['failed'] = len(re.findall(r'✘ Test', content))
        results['total_tests'] = results['passed'] + results['failed']
        
        # If no ✔/✘ found, try "Executed X tests" lines
        if results['total_tests'] == 0:
            executed_lines = re.findall(r'Executed (\d+) tests', content)
            failure_lines = re.findall(r'with (\d+) failures', content)
            
            if executed_lines:
                total = sum(int(x) for x in executed_lines)
                failures = sum(int(x) for x in failure_lines) if failure_lines else 0
                results['total_tests'] = total
                results['passed'] = total - failures
                results['failed'] = failures
        
        # Count Memory Guard skips
        results['memory_guard_skips'] = len(re.findall(r'MEMORY GUARD: Skipping', content))
        
        # Count Pool hits (from ContainerPool output)
        results['pool_hits'] = len(re.findall(r'ContainerPool.*hit|acquired from pool', content))
        
        # Count container creations
        results['container_creations'] = len(re.findall(r'container.*run|Creating container', content))
        
        # Extract duration - multiple formats
        # Format 1: "passed after 10.5 seconds"
        # Format 2: "Test Suite... (10.5 seconds)"
        duration_match = re.search(r'passed after (\d+\.\d+) seconds', content)
        if not duration_match:
            duration_match = re.search(r'\((\d+\.\d+) seconds\)', content)
        if duration_match:
            results['duration_seconds'] = float(duration_match.group(1))
        
        return results
    
    def parse_resource_csv(self) -> List[Dict]:
        """Parse resource telemetry CSV"""
        data = []
        
        if not self.resource_csv_path.exists():
            return data
            
        with open(self.resource_csv_path, 'r') as f:
            reader = csv.DictReader(f)
            for row in reader:
                try:
                    data.append({
                        'timestamp': row.get('timestamp', '') or '',
                        'free_memory_mb': int(row.get('free_memory_mb') or 0),
                        'active_memory_mb': int(row.get('active_memory_mb') or 0),
                        'cpu_percent': float(row.get('cpu_percent') or 0),
                        'container_count': int(row.get('container_count') or 0)
                    })
                except (ValueError, KeyError):
                    continue
        
        return data
    
    def analyze_resource_data(self) -> Dict:
        """Analyze resource data for peaks and trends"""
        if not self.resource_data:
            return {
                'min_free_memory': None,
                'max_cpu': None,
                'avg_containers': 0,
                'memory_pressure_events': 0,
                'critical_memory_events': 0
            }
        
        free_memories = [d['free_memory_mb'] for d in self.resource_data if d['free_memory_mb'] > 0]
        cpu_values = [d['cpu_percent'] for d in self.resource_data if d['cpu_percent'] > 0]
        container_counts = [d['container_count'] for d in self.resource_data]
        
        # Count pressure events
        memory_pressure_events = sum(1 for m in free_memories if m < MEMORY_WARNING_THRESHOLD_MB)
        critical_events = sum(1 for m in free_memories if m < MEMORY_CRITICAL_THRESHOLD_MB)
        
        return {
            'min_free_memory': min(free_memories) if free_memories else None,
            'max_cpu': max(cpu_values) if cpu_values else None,
            'avg_containers': sum(container_counts) / len(container_counts) if container_counts else 0,
            'memory_pressure_events': memory_pressure_events,
            'critical_memory_events': critical_events
        }
    
    def calculate_time_saved(self) -> Dict:
        """Calculate time saved from container pooling"""
        # Assume 3 seconds saved per pool hit (vs creating new container)
        time_saved_per_hit = 3.0
        
        pool_hits = self.test_results.get('pool_hits', 0)
        time_saved = pool_hits * time_saved_per_hit
        
        return {
            'pool_hits': pool_hits,
            'time_saved_seconds': time_saved,
            'time_saved_minutes': time_saved / 60
        }
    
    def calculate_guard_efficiency(self) -> Dict:
        """Calculate how effectively memory guard is working"""
        total_tests = self.test_results.get('total_tests', 0)
        skipped_tests = self.test_results.get('memory_guard_skips', 0)
        
        if total_tests == 0:
            return {
                'skip_rate_percent': 0,
                'skipped_tests': 0,
                'total_tests': 0,
                'recommendation': 'N/A'
            }
        
        skip_rate = (skipped_tests / total_tests) * 100
        
        recommendation = 'OK'
        if skip_rate > GUARD_EFFICIENCY_WARNING_THRESHOLD:
            recommendation = 'WARNING: Close apps (Chrome/Xcode) to free memory'
        elif skip_rate > 50:
            recommendation = 'CRITICAL: System too constrained for reliable testing'
        
        return {
            'skip_rate_percent': skip_rate,
            'skipped_tests': skipped_tests,
            'total_tests': total_tests,
            'recommendation': recommendation
        }
    
    def check_regressions(self, current: Dict) -> List[Dict]:
        """Check for performance regressions against baseline"""
        regressions = []
        
        if not self.baseline_path or not self.baseline_path.exists():
            return regressions
            
        try:
            self.baseline = json.loads(self.baseline_path.read_text())
        except json.JSONDecodeError:
            return regressions
        
        if self.baseline is None:
            return regressions
        
        baseline_resources = self.baseline.get('resources', {})
        baseline_results = self.baseline.get('test_results', {})
        
        # Check memory usage regression
        baseline_memory = baseline_resources.get('min_free_memory')
        current_memory = current.get('min_free_memory')
        
        if baseline_memory is not None and current_memory is not None and baseline_memory > 0:
            memory_change = ((baseline_memory - current_memory) / baseline_memory) * 100
            if memory_change > 50:  # 50% more memory pressure
                regressions.append({
                    'type': 'memory_pressure',
                    'severity': 'WARNING',
                    'message': f'Memory pressure increased by {memory_change:.1f}%',
                    'baseline': baseline_memory,
                    'current': current_memory
                })
        
        # Check duration regression
        baseline_duration = baseline_results.get('duration_seconds', 0)
        current_duration = self.test_results.get('duration_seconds', 0)
        
        if baseline_duration > 0 and current_duration > 0:
            duration_change = ((current_duration - baseline_duration) / baseline_duration) * 100
            if duration_change > 50:  # 50% slower
                regressions.append({
                    'type': 'duration',
                    'severity': 'ERROR',
                    'message': f'Test duration increased by {duration_change:.1f}%',
                    'baseline': baseline_duration,
                    'current': current_duration
                })
        
        # Check pgmicro container memory regression
        baseline_pgmicro = baseline_resources.get('pgmicro_memory_mb', 50)
        current_pgmicro = current.get('pgmicro_memory_mb', baseline_pgmicro)
        
        if isinstance(current_pgmicro, (int, float)) and isinstance(baseline_pgmicro, (int, float)):
            if current_pgmicro > baseline_pgmicro * 1.5:  # 50% more memory
                regressions.append({
                    'type': 'container_memory',
                    'severity': 'ERROR',
                    'message': f'pgmicro container memory increased from {baseline_pgmicro}MB to {current_pgmicro}MB',
                    'baseline': baseline_pgmicro,
                    'current': current_pgmicro
                })
        
        return regressions
    
    def generate_scorecard(self) -> str:
        """Generate human-readable sustainability scorecard"""
        # Parse all data
        self.test_results = self.parse_test_log()
        self.resource_data = self.parse_resource_csv()
        resource_analysis = self.analyze_resource_data()
        time_saved = self.calculate_time_saved()
        guard_efficiency = self.calculate_guard_efficiency()
        regressions = self.check_regressions(resource_analysis)
        
        # Build scorecard
        lines = []
        lines.append("╔" + "═" * 76 + "╗")
        lines.append("║" + " CONTAINER-COMPOSE SUSTAINABILITY SCORECARD (8GB M2 Optimized)".ljust(76) + "║")
        lines.append("╠" + "═" * 76 + "╣")
        
        # Test Summary
        lines.append("║ 📊 TEST EXECUTION SUMMARY".ljust(76) + "║")
        lines.append("╟" + "─" * 76 + "╢")
        lines.append(f"║   Total Tests:     {self.test_results['total_tests']:<48} ║")
        lines.append(f"║   Passed:          {self.test_results['passed']:<48} ║")
        lines.append(f"║   Failed:          {self.test_results['failed']:<48} ║")
        lines.append(f"║   Skipped (Guard): {self.test_results['memory_guard_skips']:<48} ║")
        lines.append(f"║   Duration:        {self.test_results['duration_seconds']:.1f}s{'':<44} ║")
        lines.append("╠" + "═" * 76 + "╣")
        
        # Memory Analysis
        lines.append("║ 🧠 MEMORY PRESSURE ANALYSIS".ljust(76) + "║")
        lines.append("╟" + "─" * 76 + "╢")
        
        if resource_analysis['min_free_memory'] is not None:
            min_mem = resource_analysis['min_free_memory']
            mem_status = "✓ OK" if min_mem > MEMORY_WARNING_THRESHOLD_MB else "⚠️ WARNING"
            lines.append(f"║   Minimum Free:    {min_mem} MB {mem_status:<41} ║")
            
            if min_mem < MEMORY_CRITICAL_THRESHOLD_MB:
                lines.append("║   ⚠️  CRITICAL: Memory dropped below 200MB - near OOM condition!".ljust(76) + "║")
            elif min_mem < MEMORY_WARNING_THRESHOLD_MB:
                lines.append("║   ⚠️  WARNING: Memory pressure detected (swap likely active)".ljust(76) + "║")
        else:
            lines.append("║   Memory data unavailable".ljust(76) + "║")
        
        lines.append(f"║   Pressure Events: {resource_analysis['memory_pressure_events']:<48} ║")
        lines.append(f"║   Critical Events: {resource_analysis['critical_memory_events']:<48} ║")
        lines.append("╠" + "═" * 76 + "╣")
        
        # Performance Optimization
        lines.append("║ ⚡ PERFORMANCE OPTIMIZATIONS".ljust(76) + "║")
        lines.append("╟" + "─" * 76 + "╢")
        lines.append(f"║   Pool Hits:       {time_saved['pool_hits']:<48} ║")
        lines.append(f"║   Time Saved:      {time_saved['time_saved_seconds']:.1f}s ({time_saved['time_saved_minutes']:.2f} min){'':<28} ║")
        lines.append(f"║   Containers:      Avg {resource_analysis['avg_containers']:.1f} running{'':<35} ║")
        lines.append("╠" + "═" * 76 + "╣")
        
        # Guard Efficiency
        lines.append("║ 🛡️  MEMORY GUARD EFFICIENCY".ljust(76) + "║")
        lines.append("╟" + "─" * 76 + "╢")
        lines.append(f"║   Skip Rate:       {guard_efficiency.get('skip_rate_percent', 0):.1f}%{'':<43} ║")
        lines.append(f"║   Tests Skipped:   {guard_efficiency.get('skipped_tests', 0)}/{guard_efficiency.get('total_tests', 0)}{'':<42} ║")
        
        if guard_efficiency['recommendation'] != 'OK':
            lines.append(f"║   Recommendation:  {guard_efficiency['recommendation']:<48} ║")
        lines.append("╠" + "═" * 76 + "╣")
        
        # Regressions
        if regressions:
            lines.append("║ 🚨 PERFORMANCE REGRESSIONS DETECTED".ljust(76) + "║")
            lines.append("╟" + "─" * 76 + "╢")
            for reg in regressions:
                severity_emoji = "🔴" if reg['severity'] == 'ERROR' else "🟡"
                lines.append(f"║   {severity_emoji} {reg['type']}: {reg['message']:<52} ║")
            lines.append("║                                                      ║")
            lines.append("║   Recommendations:                                   ║")
            lines.append("║   - Review recent changes for memory leaks         ║")
            lines.append("║   - Check container image sizes                      ║")
            lines.append("║   - Run 'make perf-baseline' to update baseline      ║")
            lines.append("╠" + "═" * 76 + "╣")
        
        # Sustainability Grade
        lines.append("║ 🏆 SUSTAINABILITY GRADE".ljust(76) + "║")
        lines.append("╟" + "─" * 76 + "╢")
        
        grade = self._calculate_grade(resource_analysis, guard_efficiency, regressions)
        lines.append(f"║   Overall Grade:   {grade['grade']} - {grade['description']:<44} ║")
        lines.append(f"║   Score:           {grade['score']}/100{'':<46} ║")
        lines.append("╚" + "═" * 76 + "╝")
        
        return '\n'.join(lines)
    
    def _calculate_grade(self, resources: Dict, guard: Dict, regressions: List) -> Dict:
        """Calculate sustainability grade"""
        score = 100
        
        # Deduct for memory pressure
        min_free = resources.get('min_free_memory')
        if min_free is not None:
            if min_free < MEMORY_CRITICAL_THRESHOLD_MB:
                score -= 40
            elif min_free < MEMORY_WARNING_THRESHOLD_MB:
                score -= 20
        
        # Deduct for guard skips
        if guard.get('skip_rate_percent', 0) > 50:
            score -= 30
        elif guard.get('skip_rate_percent', 0) > 20:
            score -= 15
        
        # Deduct for regressions
        for reg in regressions:
            if reg['severity'] == 'ERROR':
                score -= 20
            else:
                score -= 10
        
        # Clamp score
        score = max(0, min(100, score))
        
        # Determine grade
        if score >= 90:
            return {'grade': 'A', 'description': 'Excellent - Harness is well-tuned', 'score': score}
        elif score >= 75:
            return {'grade': 'B', 'description': 'Good - Minor optimizations possible', 'score': score}
        elif score >= 60:
            return {'grade': 'C', 'description': 'Fair - Memory pressure detected', 'score': score}
        elif score >= 40:
            return {'grade': 'D', 'description': 'Poor - Frequent OOM risk', 'score': score}
        else:
            return {'grade': 'F', 'description': 'Critical - System unsustainable', 'score': score}
    
    def save_baseline(self, path: str):
        """Save current run as baseline for future comparison"""
        baseline = {
            'timestamp': datetime.now().isoformat(),
            'test_results': self.test_results,
            'resources': self.analyze_resource_data(),
            'pgmicro_memory_mb': 50  # Expected baseline
        }
        
        Path(path).write_text(json.dumps(baseline, indent=2))
        print(f"✓ Baseline saved to: {path}")


def main():
    if len(sys.argv) < 3:
        print("Usage: python3 scripts/analyze-performance.py <test_log> <resource_csv> [--baseline baseline.json]")
        print("       python3 scripts/analyze-performance.py <test_log> <resource_csv> --save-baseline baseline.json")
        sys.exit(1)
    
    test_log = sys.argv[1]
    resource_csv = sys.argv[2]
    
    baseline = None
    save_baseline_path = None
    
    if '--baseline' in sys.argv:
        idx = sys.argv.index('--baseline')
        if idx + 1 < len(sys.argv):
            baseline = sys.argv[idx + 1]
    
    if '--save-baseline' in sys.argv:
        idx = sys.argv.index('--save-baseline')
        if idx + 1 < len(sys.argv):
            save_baseline_path = sys.argv[idx + 1]
    
    analyzer = PerformanceAnalyzer(test_log, resource_csv, baseline)
    
    # Generate and print scorecard
    scorecard = analyzer.generate_scorecard()
    print(scorecard)
    
    # Save baseline if requested
    if save_baseline_path:
        analyzer.save_baseline(save_baseline_path)
    
    # Exit with error code if regressions detected
    regressions = analyzer.check_regressions(analyzer.analyze_resource_data())
    if any(r['severity'] == 'ERROR' for r in regressions):
        sys.exit(1)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""
Analyze container telemetry CSV to derive empirical memory profiles
Usage: python3 analyze-container-telemetry.py <telemetry.csv> [--profiles profiles.json]
"""

import csv
import json
import argparse
import sys
from collections import defaultdict
from datetime import datetime
from typing import Dict, List, Any

def parse_memory_mb(value: str) -> float:
    """Parse memory value to MB"""
    try:
        return float(value)
    except:
        return 0.0

def load_telemetry(path: str) -> List[Dict]:
    """Load telemetry CSV"""
    samples = []
    with open(path, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            samples.append(row)
    return samples

def build_profiles(samples: List[Dict]) -> Dict[str, Dict]:
    """Build per-image profiles from telemetry"""
    image_stats = defaultdict(lambda: {'memorys': [], 'limits': []})

    for sample in samples:
        image = sample.get('image_reference', 'unknown')
        try:
            usage_mb = float(sample.get('memory_usage_mb', 0))
            limit_mb = float(sample.get('memory_limit_mb', 0))
        except:
            continue

        image_stats[image]['memorys'].append(usage_mb)
        image_stats[image]['limits'].append(limit_mb)

    profiles = {}
    for image, stats in image_stats.items():
        memories = sorted(stats['memorys'])
        if not memories:
            continue

        mean_mb = sum(memories) / len(memories)
        peak_mb = max(memories)
        p95_idx = int(len(memories) * 0.95)
        p95_mb = memories[min(p95_idx, len(memories) - 1)]

        # Calculate recommended limit (peak + 15% headroom)
        recommended_mb = peak_mb * 1.15

        profiles[image] = {
            'image': image,
            'mean_mb': round(mean_mb, 1),
            'peak_mb': round(peak_mb, 1),
            'p95_mb': round(p95_mb, 1),
            'recommended_mb': round(recommended_mb, 1),
            'sample_count': len(memories),
            'efficiency': round((mean_mb / peak_mb) * 100, 1) if peak_mb > 0 else 0
        }

    return profiles

def detect_regressions(current_samples: List[Dict], baseline_profiles: Dict) -> List[str]:
    """Detect memory regressions compared to baseline"""
    current_profiles = build_profiles(current_samples)
    regressions = []

    for image, current in current_profiles.items():
        if image not in baseline_profiles:
            continue

        baseline = baseline_profiles[image]
        baseline_peak = baseline.get('peak_mb', 0)
        current_peak = current['peak_mb']

        if baseline_peak > 0:
            increase_pct = ((current_peak - baseline_peak) / baseline_peak) * 100
            if increase_pct > 30:
                regressions.append(
                    f"{image}: +{increase_pct:.1f}% increase "
                    f"({baseline_peak:.1f}MB → {current_peak:.1f}MB)"
                )

    return regressions

def print_report(profiles: Dict[str, Dict], regressions: List[str] = []):
    """Print formatted report"""
    print("=" * 80)
    print("CONTAINER TELEMETRY ANALYSIS")
    print("=" * 80)
    print()

    if regressions:
        print("⚠️  MEMORY REGRESSIONS DETECTED:")
        for r in regressions:
            print(f"   {r}")
        print()

    print(f"{'Image':<35} {'Mean(MB)':>10} {'Peak(MB)':>10} {'P95(MB)':>10} {'Recommend':>10} {'Samples':>8}")
    print("-" * 95)

    total_mean = 0
    total_peak = 0
    total_recommended = 0

    for image, profile in sorted(profiles.items(), key=lambda x: x[1]['peak_mb'], reverse=True):
        print(f"{image[:35]:<35} {profile['mean_mb']:>10.1f} {profile['peak_mb']:>10.1f} "
              f"{profile['p95_mb']:>10.1f} {profile['recommended_mb']:>10.1f} {profile['sample_count']:>8}")

        total_mean += profile['mean_mb']
        total_peak += profile['peak_mb']
        total_recommended += profile['recommended_mb']

    print("-" * 95)
    print(f"{'TOTAL':<35} {total_mean:>10.1f} {total_peak:>10.1f} {'':>10} {total_recommended:>10.1f}")
    print()

    # Efficiency analysis
    avg_efficiency = sum(p['efficiency'] for p in profiles.values()) / len(profiles) if profiles else 0
    print(f"Average efficiency: {avg_efficiency:.1f}% (mean/peak ratio)")
    print()

    # Recommendations
    print("RECOMMENDATIONS:")
    over_provisioned = [p for p in profiles.values() if p['peak_mb'] < p['recommended_mb'] * 0.5]
    if over_provisioned:
        print(f"  • {len(over_provisioned)} images may be over-provisioned (peak < 50% of limit)")
    print(f"  • Total potential savings: {sum(p['recommended_mb'] - p['peak_mb'] for p in profiles.values()):.0f}MB")
    print()

def save_profiles(profiles: Dict[str, Dict], path: str):
    """Save profiles to JSON"""
    data = {
        'generated_at': datetime.now().isoformat(),
        'profiles': profiles
    }
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print(f"Profiles saved to: {path}")

def load_profiles(path: str) -> Dict[str, Dict]:
    """Load profiles from JSON"""
    with open(path, 'r') as f:
        data = json.load(f)
    return data.get('profiles', {})

def main():
    parser = argparse.ArgumentParser(description='Analyze container telemetry')
    parser.add_argument('telemetry', help='Telemetry CSV file')
    parser.add_argument('--profiles', help='Load baseline profiles for regression detection')
    parser.add_argument('--save', help='Save computed profiles to JSON file')
    parser.add_argument('--json', action='store_true', help='Output as JSON')
    args = parser.parse_args()

    # Load telemetry
    try:
        samples = load_telemetry(args.telemetry)
    except Exception as e:
        print(f"Error loading telemetry: {e}", file=sys.stderr)
        sys.exit(1)

    if not samples:
        print("No telemetry samples found")
        sys.exit(0)

    # Build current profiles
    profiles = build_profiles(samples)

    # Detect regressions if baseline provided
    regressions = []
    if args.profiles:
        try:
            baseline = load_profiles(args.profiles)
            regressions = detect_regressions(samples, baseline)
        except Exception as e:
            print(f"Warning: Could not load baseline: {e}", file=sys.stderr)

    # Save profiles if requested
    if args.save:
        save_profiles(profiles, args.save)

    # Output
    if args.json:
        print(json.dumps({
            'profiles': profiles,
            'regressions': regressions,
            'total_samples': len(samples)
        }, indent=2))
    else:
        print_report(profiles, regressions)

if __name__ == '__main__':
    main()

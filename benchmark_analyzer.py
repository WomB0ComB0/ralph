#!/usr/bin/env python3
import json
import sys
import os
import argparse
from datetime import datetime

def parse_metrics(file_path):
    metrics = []
    if not os.path.exists(file_path):
        print(f"Error: Metrics file not found at {file_path}")
        return metrics
    
    with open(file_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                metrics.append(json.loads(line))
            except json.JSONDecodeError:
                # Handle old format if necessary, or just skip
                continue
    return metrics

def calculate_stats(metrics):
    if not metrics:
        return None
    
    total_iterations = len(metrics)
    total_latency = sum(m.get('latency', 0) for m in metrics)
    total_tokens = sum(m.get('tokens', 0) for m in metrics)
    
    avg_latency = total_latency / total_iterations if total_iterations > 0 else 0
    avg_tokens = total_tokens / total_iterations if total_iterations > 0 else 0
    
    max_lazy = max(m.get('lazy_streak', 0) for m in metrics)
    
    tools = {}
    models = {}
    
    for m in metrics:
        t = m.get('tool', 'unknown')
        tools[t] = tools.get(t, 0) + 1
        mdl = m.get('model', 'unknown')
        models[mdl] = models.get(mdl, 0) + 1
        
    return {
        'total_iterations': total_iterations,
        'total_latency': total_latency,
        'total_tokens': total_tokens,
        'avg_latency': avg_latency,
        'avg_tokens': avg_tokens,
        'max_lazy': max_lazy,
        'tools': tools,
        'models': models
    }

def generate_report(stats, output_file=None):
    if not stats:
        print("No statistics to report.")
        return
    
    report = []
    report.append("# Ralph Performance Benchmark Report")
    report.append(f"\nGenerated on: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    
    report.append("\n## Summary Metrics")
    report.append(f"- **Total Iterations:** {stats['total_iterations']}")
    report.append(f"- **Total Execution Time:** {stats['total_latency']:.2f}s")
    report.append(f"- **Total Tokens (Est):** {stats['total_tokens']}")
    report.append(f"- **Average Latency/Iteration:** {stats['avg_latency']:.2f}s")
    report.append(f"- **Average Tokens/Iteration:** {stats['avg_tokens']:.1f}")
    report.append(f"- **Max Lazy Streak:** {stats['max_lazy']}")
    
    report.append("\n## Utilization")
    report.append("\n### Tools Used")
    for tool, count in stats['tools'].items():
        report.append(f"- {tool}: {count} iterations")
        
    report.append("\n### Models Used")
    for model, count in stats['models'].items():
        report.append(f"- {model}: {count} iterations")
        
    report_text = "\n".join(report)
    
    if output_file:
        with open(output_file, 'w') as f:
            f.write(report_text)
        print(f"Report generated at {output_file}")
    else:
        print(report_text)

def main():
    parser = argparse.ArgumentParser(description="Ralph Benchmark Analyzer")
    parser.add_argument("--input", default=".ralph/state/metrics.json", help="Path to metrics.json (JSONL)")
    parser.add_argument("--output", help="Path to save markdown report")
    
    args = parser.parse_args()
    
    metrics = parse_metrics(args.input)
    stats = calculate_stats(metrics)
    generate_report(stats, args.output)

if __name__ == "__main__":
    main()

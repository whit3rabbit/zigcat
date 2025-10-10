#!/usr/bin/env python3
"""
Trend Analysis for ZigCat Docker Test Suite

This script analyzes historical test results to identify trends,
performance regressions, and improvements over time.
"""

import json
import os
import sys
import argparse
import datetime
from pathlib import Path
from typing import Dict, List, Any, Optional, Tuple
import statistics


class TrendAnalyzer:
    """Analyzes trends in test results over time."""
    
    def __init__(self, reports_dir: str):
        self.reports_dir = Path(reports_dir)
        self.historical_data = self._load_historical_data()
    
    def _load_historical_data(self) -> List[Dict[str, Any]]:
        """Load all historical test reports."""
        reports = []
        
        # Find all JSON test reports
        for report_file in sorted(self.reports_dir.glob("test-report-*.json")):
            try:
                with open(report_file) as f:
                    data = json.load(f)
                    # Add metadata
                    data["report_file"] = str(report_file)
                    data["report_date"] = self._extract_date_from_filename(report_file.name)
                    reports.append(data)
            except (json.JSONDecodeError, FileNotFoundError) as e:
                print(f"Warning: Could not load {report_file}: {e}")
        
        return sorted(reports, key=lambda x: x.get("timestamp", ""))
    
    def _extract_date_from_filename(self, filename: str) -> Optional[str]:
        """Extract date from report filename."""
        try:
            # Extract timestamp from filename like "test-report-20251005-143000.json"
            parts = filename.replace("test-report-", "").replace(".json", "").split("-")
            if len(parts) >= 2:
                date_str = f"{parts[0]}-{parts[1]}"
                # Convert to ISO format
                dt = datetime.datetime.strptime(date_str, "%Y%m%d-%H%M%S")
                return dt.isoformat()
        except (ValueError, IndexError):
            pass
        return None
    
    def analyze_success_rate_trends(self) -> Dict[str, Any]:
        """Analyze success rate trends over time."""
        trends = {
            "overall_trend": [],
            "platform_trends": {},
            "regression_points": [],
            "improvement_points": []
        }
        
        for report in self.historical_data:
            timestamp = report.get("timestamp", report.get("report_date", ""))
            summary = report.get("summary", {})
            
            success_rate = summary.get("success_rate", 0)
            trends["overall_trend"].append({
                "timestamp": timestamp,
                "success_rate": success_rate,
                "total_tests": summary.get("total_tests", 0),
                "failed_tests": summary.get("failed_tests", 0)
            })
            
            # Analyze platform-specific trends
            platform_matrix = report.get("platform_matrix", {})
            for platform, data in platform_matrix.items():
                if platform not in trends["platform_trends"]:
                    trends["platform_trends"][platform] = []
                
                platform_success = 1.0 if data.get("test_status") == "pass" else 0.0
                trends["platform_trends"][platform].append({
                    "timestamp": timestamp,
                    "success": platform_success,
                    "build_status": data.get("build_status", "unknown"),
                    "issues_count": len(data.get("issues", []))
                })
        
        # Identify regression and improvement points
        if len(trends["overall_trend"]) >= 2:
            for i in range(1, len(trends["overall_trend"])):
                current = trends["overall_trend"][i]
                previous = trends["overall_trend"][i-1]
                
                rate_change = current["success_rate"] - previous["success_rate"]
                
                if rate_change < -5.0:  # 5% regression threshold
                    trends["regression_points"].append({
                        "timestamp": current["timestamp"],
                        "change": rate_change,
                        "from_rate": previous["success_rate"],
                        "to_rate": current["success_rate"]
                    })
                elif rate_change > 5.0:  # 5% improvement threshold
                    trends["improvement_points"].append({
                        "timestamp": current["timestamp"],
                        "change": rate_change,
                        "from_rate": previous["success_rate"],
                        "to_rate": current["success_rate"]
                    })
        
        return trends
    
    def analyze_performance_trends(self) -> Dict[str, Any]:
        """Analyze performance trends over time."""
        trends = {
            "duration_trends": [],
            "binary_size_trends": {},
            "build_time_trends": {},
            "performance_regressions": []
        }
        
        for report in self.historical_data:
            timestamp = report.get("timestamp", report.get("report_date", ""))
            summary = report.get("summary", {})
            performance = report.get("performance_metrics", {})
            
            # Overall duration trend
            trends["duration_trends"].append({
                "timestamp": timestamp,
                "total_duration": summary.get("total_duration", 0),
                "average_test_duration": summary.get("average_test_duration", 0),
                "total_tests": summary.get("total_tests", 0)
            })
            
            # Binary size trends
            binary_sizes = performance.get("binary_sizes", {})
            for platform, size in binary_sizes.items():
                if platform not in trends["binary_size_trends"]:
                    trends["binary_size_trends"][platform] = []
                
                trends["binary_size_trends"][platform].append({
                    "timestamp": timestamp,
                    "size": size
                })
            
            # Build time trends
            build_times = performance.get("build_times", {})
            for platform, time in build_times.items():
                if platform not in trends["build_time_trends"]:
                    trends["build_time_trends"][platform] = []
                
                trends["build_time_trends"][platform].append({
                    "timestamp": timestamp,
                    "build_time": time
                })
        
        # Identify performance regressions
        if len(trends["duration_trends"]) >= 2:
            for i in range(1, len(trends["duration_trends"])):
                current = trends["duration_trends"][i]
                previous = trends["duration_trends"][i-1]
                
                if (current["total_tests"] > 0 and previous["total_tests"] > 0):
                    current_avg = current["average_test_duration"]
                    previous_avg = previous["average_test_duration"]
                    
                    if previous_avg > 0:
                        change_percent = ((current_avg - previous_avg) / previous_avg) * 100
                        
                        if change_percent > 20:  # 20% performance regression threshold
                            trends["performance_regressions"].append({
                                "timestamp": current["timestamp"],
                                "change_percent": change_percent,
                                "from_duration": previous_avg,
                                "to_duration": current_avg
                            })
        
        return trends
    
    def analyze_failure_patterns(self) -> Dict[str, Any]:
        """Analyze failure patterns over time."""
        patterns = {
            "recurring_failures": {},
            "platform_stability": {},
            "failure_frequency": [],
            "most_problematic_tests": {}
        }
        
        all_failures = {}
        platform_failures = {}
        
        for report in self.historical_data:
            timestamp = report.get("timestamp", report.get("report_date", ""))
            failure_analysis = report.get("failure_analysis", {})
            
            # Track failure frequency over time
            total_failures = failure_analysis.get("total_failures", 0)
            patterns["failure_frequency"].append({
                "timestamp": timestamp,
                "total_failures": total_failures
            })
            
            # Collect all failure details
            for failure in failure_analysis.get("failure_details", []):
                test_name = failure.get("test_name", "unknown")
                platform = failure.get("platform", "unknown")
                error_type = failure.get("error_type", "unknown")
                
                # Track recurring failures
                failure_key = f"{test_name}:{error_type}"
                if failure_key not in all_failures:
                    all_failures[failure_key] = []
                all_failures[failure_key].append({
                    "timestamp": timestamp,
                    "platform": platform,
                    "error_message": failure.get("error_message", "")
                })
                
                # Track platform stability
                if platform not in platform_failures:
                    platform_failures[platform] = []
                platform_failures[platform].append({
                    "timestamp": timestamp,
                    "test_name": test_name,
                    "error_type": error_type
                })
        
        # Identify recurring failures (appearing in multiple reports)
        for failure_key, occurrences in all_failures.items():
            if len(occurrences) > 1:
                patterns["recurring_failures"][failure_key] = {
                    "occurrences": len(occurrences),
                    "platforms": list(set(occ["platform"] for occ in occurrences)),
                    "first_seen": min(occ["timestamp"] for occ in occurrences),
                    "last_seen": max(occ["timestamp"] for occ in occurrences),
                    "details": occurrences
                }
        
        # Calculate platform stability scores
        for platform, failures in platform_failures.items():
            total_reports = len(self.historical_data)
            reports_with_failures = len(set(f["timestamp"] for f in failures))
            stability_score = ((total_reports - reports_with_failures) / total_reports) * 100
            
            patterns["platform_stability"][platform] = {
                "stability_score": stability_score,
                "total_failures": len(failures),
                "reports_with_failures": reports_with_failures,
                "total_reports": total_reports
            }
        
        # Identify most problematic tests
        test_failure_counts = {}
        for failure_key, data in patterns["recurring_failures"].items():
            test_name = failure_key.split(":")[0]
            if test_name not in test_failure_counts:
                test_failure_counts[test_name] = 0
            test_failure_counts[test_name] += data["occurrences"]
        
        patterns["most_problematic_tests"] = dict(
            sorted(test_failure_counts.items(), key=lambda x: x[1], reverse=True)[:10]
        )
        
        return patterns
    
    def generate_trend_report(self, output_file: str) -> None:
        """Generate comprehensive trend analysis report."""
        if len(self.historical_data) < 2:
            print("Warning: Need at least 2 historical reports for trend analysis")
            return
        
        success_trends = self.analyze_success_rate_trends()
        performance_trends = self.analyze_performance_trends()
        failure_patterns = self.analyze_failure_patterns()
        
        report = {
            "analysis_timestamp": datetime.datetime.utcnow().isoformat() + "Z",
            "reports_analyzed": len(self.historical_data),
            "date_range": {
                "from": self.historical_data[0].get("timestamp", "unknown"),
                "to": self.historical_data[-1].get("timestamp", "unknown")
            },
            "success_rate_trends": success_trends,
            "performance_trends": performance_trends,
            "failure_patterns": failure_patterns,
            "recommendations": self._generate_recommendations(
                success_trends, performance_trends, failure_patterns
            )
        }
        
        with open(output_file, 'w') as f:
            json.dump(report, f, indent=2, sort_keys=True)
        
        print(f"Trend analysis report generated: {output_file}")
    
    def _generate_recommendations(self, success_trends: Dict, performance_trends: Dict, 
                                failure_patterns: Dict) -> List[str]:
        """Generate actionable recommendations based on trend analysis."""
        recommendations = []
        
        # Success rate recommendations
        if success_trends["regression_points"]:
            recommendations.append(
                f"Address {len(success_trends['regression_points'])} success rate regressions identified"
            )
        
        # Performance recommendations
        if performance_trends["performance_regressions"]:
            recommendations.append(
                f"Investigate {len(performance_trends['performance_regressions'])} performance regressions"
            )
        
        # Platform stability recommendations
        unstable_platforms = [
            platform for platform, data in failure_patterns["platform_stability"].items()
            if data["stability_score"] < 80
        ]
        if unstable_platforms:
            recommendations.append(
                f"Focus on improving stability for platforms: {', '.join(unstable_platforms)}"
            )
        
        # Recurring failure recommendations
        if failure_patterns["recurring_failures"]:
            top_recurring = sorted(
                failure_patterns["recurring_failures"].items(),
                key=lambda x: x[1]["occurrences"],
                reverse=True
            )[:3]
            
            for failure_key, data in top_recurring:
                recommendations.append(
                    f"Fix recurring failure: {failure_key} (seen {data['occurrences']} times)"
                )
        
        # Binary size recommendations
        for platform, size_data in performance_trends["binary_size_trends"].items():
            if len(size_data) >= 2:
                recent_size = size_data[-1]["size"]
                if recent_size > 500000:  # 500KB threshold
                    recommendations.append(
                        f"Consider optimizing binary size for {platform} (current: {recent_size} bytes)"
                    )
        
        return recommendations
    
    def generate_html_trend_report(self, output_file: str) -> None:
        """Generate HTML trend visualization report."""
        if len(self.historical_data) < 2:
            print("Warning: Need at least 2 historical reports for trend analysis")
            return
        
        success_trends = self.analyze_success_rate_trends()
        performance_trends = self.analyze_performance_trends()
        failure_patterns = self.analyze_failure_patterns()
        
        html_content = self._generate_trend_html(success_trends, performance_trends, failure_patterns)
        
        with open(output_file, 'w') as f:
            f.write(html_content)
        
        print(f"HTML trend report generated: {output_file}")
    
    def _generate_trend_html(self, success_trends: Dict, performance_trends: Dict, 
                           failure_patterns: Dict) -> str:
        """Generate HTML content for trend report."""
        html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ZigCat Test Trends - {len(self.historical_data)} Reports</title>
    <style>
        body {{ font-family: Arial, sans-serif; margin: 20px; background-color: #f5f5f5; }}
        .container {{ max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }}
        .header {{ text-align: center; margin-bottom: 30px; }}
        .section {{ margin-bottom: 30px; }}
        .trend-chart {{ background: #f8f9fa; padding: 15px; border-radius: 6px; margin: 10px 0; }}
        .metric {{ display: inline-block; margin: 10px; padding: 10px; background: #e9ecef; border-radius: 4px; }}
        .regression {{ background-color: #f8d7da; color: #721c24; padding: 10px; margin: 5px 0; border-radius: 4px; }}
        .improvement {{ background-color: #d4edda; color: #155724; padding: 10px; margin: 5px 0; border-radius: 4px; }}
        .recommendation {{ background-color: #cce5ff; padding: 10px; margin: 5px 0; border-radius: 4px; border-left: 4px solid #007bff; }}
        .platform-stability {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; }}
        .stability-item {{ padding: 10px; border-radius: 4px; text-align: center; }}
        .stable {{ background-color: #d4edda; }}
        .unstable {{ background-color: #f8d7da; }}
        .moderate {{ background-color: #fff3cd; }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>ZigCat Test Trend Analysis</h1>
            <p>Analysis of {len(self.historical_data)} test reports</p>
            <p>Date Range: {self.historical_data[0].get('timestamp', 'unknown')[:10]} to {self.historical_data[-1].get('timestamp', 'unknown')[:10]}</p>
        </div>
        
        <div class="section">
            <h2>Success Rate Trends</h2>"""
        
        # Success rate overview
        if success_trends["overall_trend"]:
            latest = success_trends["overall_trend"][-1]
            earliest = success_trends["overall_trend"][0]
            
            html += f"""
            <div class="metric">
                <strong>Current Success Rate:</strong> {latest['success_rate']:.1f}%
            </div>
            <div class="metric">
                <strong>Change from Start:</strong> {latest['success_rate'] - earliest['success_rate']:+.1f}%
            </div>"""
        
        # Regressions and improvements
        if success_trends["regression_points"]:
            html += f"""
            <h3>Regressions Detected ({len(success_trends['regression_points'])})</h3>"""
            for regression in success_trends["regression_points"][-5:]:  # Show last 5
                html += f"""
            <div class="regression">
                {regression['timestamp'][:10]}: Success rate dropped from {regression['from_rate']:.1f}% to {regression['to_rate']:.1f}% ({regression['change']:+.1f}%)
            </div>"""
        
        if success_trends["improvement_points"]:
            html += f"""
            <h3>Improvements Detected ({len(success_trends['improvement_points'])})</h3>"""
            for improvement in success_trends["improvement_points"][-5:]:  # Show last 5
                html += f"""
            <div class="improvement">
                {improvement['timestamp'][:10]}: Success rate improved from {improvement['from_rate']:.1f}% to {improvement['to_rate']:.1f}% ({improvement['change']:+.1f}%)
            </div>"""
        
        html += """
        </div>
        
        <div class="section">
            <h2>Platform Stability</h2>
            <div class="platform-stability">"""
        
        for platform, stability in failure_patterns["platform_stability"].items():
            score = stability["stability_score"]
            css_class = "stable" if score >= 90 else "unstable" if score < 70 else "moderate"
            
            html += f"""
                <div class="stability-item {css_class}">
                    <h4>{platform}</h4>
                    <div><strong>{score:.1f}%</strong> stable</div>
                    <div>{stability['total_failures']} total failures</div>
                    <div>{stability['reports_with_failures']}/{stability['total_reports']} reports affected</div>
                </div>"""
        
        html += """
            </div>
        </div>"""
        
        # Performance trends
        if performance_trends["performance_regressions"]:
            html += f"""
        <div class="section">
            <h2>Performance Regressions ({len(performance_trends['performance_regressions'])})</h2>"""
            
            for regression in performance_trends["performance_regressions"][-5:]:
                html += f"""
            <div class="regression">
                {regression['timestamp'][:10]}: Average test duration increased by {regression['change_percent']:.1f}% 
                (from {regression['from_duration']:.2f}s to {regression['to_duration']:.2f}s)
            </div>"""
            
            html += """
        </div>"""
        
        # Recurring failures
        if failure_patterns["recurring_failures"]:
            html += f"""
        <div class="section">
            <h2>Recurring Failures ({len(failure_patterns['recurring_failures'])})</h2>"""
            
            top_recurring = sorted(
                failure_patterns["recurring_failures"].items(),
                key=lambda x: x[1]["occurrences"],
                reverse=True
            )[:10]
            
            for failure_key, data in top_recurring:
                html += f"""
            <div class="regression">
                <strong>{failure_key}</strong>: {data['occurrences']} occurrences<br>
                Platforms: {', '.join(data['platforms'])}<br>
                First seen: {data['first_seen'][:10]}, Last seen: {data['last_seen'][:10]}
            </div>"""
            
            html += """
        </div>"""
        
        # Recommendations
        recommendations = self._generate_recommendations(success_trends, performance_trends, failure_patterns)
        if recommendations:
            html += f"""
        <div class="section">
            <h2>Recommendations</h2>"""
            
            for rec in recommendations:
                html += f"""
            <div class="recommendation">
                {rec}
            </div>"""
            
            html += """
        </div>"""
        
        html += """
    </div>
</body>
</html>"""
        
        return html


def main():
    parser = argparse.ArgumentParser(description="Analyze ZigCat Docker test trends")
    parser.add_argument("--reports-dir", default="docker-tests/reports",
                       help="Directory containing historical test reports")
    parser.add_argument("--output-dir", default="docker-tests/reports",
                       help="Output directory for trend reports")
    parser.add_argument("--formats", nargs="+", 
                       choices=["json", "html"], 
                       default=["json", "html"],
                       help="Report formats to generate")
    
    args = parser.parse_args()
    
    # Create output directory
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Initialize analyzer
    analyzer = TrendAnalyzer(args.reports_dir)
    
    if len(analyzer.historical_data) < 2:
        print("Error: Need at least 2 historical reports for trend analysis")
        print(f"Found {len(analyzer.historical_data)} reports in {args.reports_dir}")
        sys.exit(1)
    
    # Generate timestamp for report files
    timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    
    # Generate requested report formats
    if "json" in args.formats:
        analyzer.generate_trend_report(output_dir / f"trend-analysis-{timestamp}.json")
    
    if "html" in args.formats:
        analyzer.generate_html_trend_report(output_dir / f"trend-analysis-{timestamp}.html")
    
    print(f"Trend analysis completed. Analyzed {len(analyzer.historical_data)} reports.")


if __name__ == "__main__":
    main()
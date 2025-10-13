#!/usr/bin/env python3
"""
Result Aggregation System for ZigCat Docker Test Suite

This script aggregates test results from multiple platforms and generates
comprehensive reports including JSON, HTML, and text formats.
"""

import json
import os
import sys
import argparse
import datetime
from datetime import timezone
from pathlib import Path
from typing import Dict, List, Any, Optional
import xml.etree.ElementTree as ET


class TestResultAggregator:
    """Aggregates and processes test results from multiple platforms."""
    
    def __init__(self, results_dir: str, artifacts_dir: str):
        self.results_dir = Path(results_dir)
        self.artifacts_dir = Path(artifacts_dir)
        self.session_id = self._get_session_id()
        
    def _get_session_id(self) -> str:
        """Get the current session ID from results directory."""
        session_file = self.results_dir / "session-id"
        if session_file.exists():
            return session_file.read_text().strip()
        return f"session-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}"
    
    def collect_results(self) -> Dict[str, Any]:
        """Collect all test results and build artifacts."""
        results = {
            "session_id": self.session_id,
            "timestamp": datetime.datetime.now(timezone.utc).isoformat(),
            "test_system": "zigcat-docker-tests",
            "build_results": self._collect_build_results(),
            "test_results": self._collect_test_results(),
            "platform_matrix": self._generate_platform_matrix(),
            "summary": self._generate_summary(),
            "performance_metrics": self._collect_performance_metrics(),
            "failure_analysis": self._analyze_failures()
        }
        return results
    
    def _collect_build_results(self) -> Dict[str, Any]:
        """Collect build results from artifacts directory."""
        build_report_file = self.artifacts_dir / "build-report.json"
        if not build_report_file.exists():
            return {"status": "no_build_data", "artifacts": []}
        
        with open(build_report_file) as f:
            build_data = json.load(f)
        
        return build_data.get("build_report", {})
    
    def _collect_test_results(self) -> List[Dict[str, Any]]:
        """Collect test results from all platform test runs."""
        test_results = []
        
        # Look for platform-specific test result files
        for result_file in self.results_dir.glob("test-results-*.json"):
            try:
                with open(result_file) as f:
                    platform_results = json.load(f)
                    test_results.append(platform_results)
            except (json.JSONDecodeError, FileNotFoundError) as e:
                print(f"Warning: Could not load {result_file}: {e}")
        
        # Also check main test-report.json
        main_report = self.results_dir / "test-report.json"
        if main_report.exists():
            try:
                with open(main_report) as f:
                    main_data = json.load(f)
                    if "results" in main_data.get("test_report", {}):
                        test_results.extend(main_data["test_report"]["results"])
            except (json.JSONDecodeError, FileNotFoundError) as e:
                print(f"Warning: Could not load main test report: {e}")
        
        return test_results
    
    def _generate_platform_matrix(self) -> Dict[str, Dict[str, str]]:
        """Generate a platform compatibility matrix."""
        matrix = {}
        build_results = self._collect_build_results()
        test_results = self._collect_test_results()
        
        # Initialize matrix from build results
        for artifact in build_results.get("artifacts", []):
            platform_key = f"{artifact['platform']}-{artifact['architecture']}"
            matrix[platform_key] = {
                "build_status": "pass" if artifact.get("build_success", False) else "fail",
                "test_status": "not_run",
                "binary_size": artifact.get("binary_size", 0),
                "issues": []
            }
        
        # Update with test results
        for test_result in test_results:
            platform_key = test_result.get("platform_key", "unknown")
            if platform_key in matrix:
                matrix[platform_key]["test_status"] = test_result.get("overall_status", "unknown")
                if test_result.get("failed_tests", 0) > 0:
                    matrix[platform_key]["issues"].extend(
                        test_result.get("failure_details", [])
                    )
        
        return matrix
    
    def _generate_summary(self) -> Dict[str, Any]:
        """Generate overall test run summary."""
        build_results = self._collect_build_results()
        test_results = self._collect_test_results()
        
        total_platforms = len(build_results.get("artifacts", []))
        successful_builds = sum(1 for a in build_results.get("artifacts", []) 
                               if a.get("build_success", False))
        
        total_tests = sum(r.get("total_tests", 0) for r in test_results)
        passed_tests = sum(r.get("passed_tests", 0) for r in test_results)
        failed_tests = sum(r.get("failed_tests", 0) for r in test_results)
        skipped_tests = sum(r.get("skipped_tests", 0) for r in test_results)
        
        total_duration = sum(r.get("duration", 0) for r in test_results)
        
        return {
            "total_platforms": total_platforms,
            "successful_builds": successful_builds,
            "failed_builds": total_platforms - successful_builds,
            "total_tests": total_tests,
            "passed_tests": passed_tests,
            "failed_tests": failed_tests,
            "skipped_tests": skipped_tests,
            "success_rate": (passed_tests / total_tests * 100) if total_tests > 0 else 0,
            "total_duration": total_duration,
            "average_test_duration": (total_duration / total_tests) if total_tests > 0 else 0
        }
    
    def _collect_performance_metrics(self) -> Dict[str, Any]:
        """Collect performance metrics across platforms."""
        test_results = self._collect_test_results()
        build_results = self._collect_build_results()
        
        metrics = {
            "build_times": {},
            "test_durations": {},
            "binary_sizes": {},
            "resource_usage": {}
        }
        
        # Collect build times and binary sizes
        for artifact in build_results.get("artifacts", []):
            platform_key = f"{artifact['platform']}-{artifact['architecture']}"
            metrics["binary_sizes"][platform_key] = artifact.get("binary_size", 0)
            
            # Try to extract build time from logs
            log_path = artifact.get("log_path")
            if log_path and os.path.exists(log_path):
                build_time = self._extract_build_time(log_path)
                if build_time:
                    metrics["build_times"][platform_key] = build_time
        
        # Collect test durations
        for test_result in test_results:
            platform_key = test_result.get("platform_key", "unknown")
            metrics["test_durations"][platform_key] = test_result.get("duration", 0)
        
        return metrics
    
    def _extract_build_time(self, log_path: str) -> Optional[float]:
        """Extract build time from build log file."""
        try:
            with open(log_path) as f:
                content = f.read()
                # Look for timing information in build logs
                # This is a simplified implementation
                lines = content.split('\n')
                for line in lines:
                    if "Build completed in" in line or "Total time:" in line:
                        # Extract time value (implementation depends on log format)
                        pass
        except Exception:
            pass
        return None
    
    def _analyze_failures(self) -> Dict[str, Any]:
        """Analyze test failures and categorize them."""
        test_results = self._collect_test_results()
        
        failure_analysis = {
            "total_failures": 0,
            "failure_categories": {},
            "platform_specific_failures": {},
            "common_failures": [],
            "failure_details": []
        }
        
        all_failures = []
        platform_failures = {}
        
        for test_result in test_results:
            platform_key = test_result.get("platform_key", "unknown")
            failures = test_result.get("failure_details", [])
            
            failure_analysis["total_failures"] += len(failures)
            platform_failures[platform_key] = failures
            all_failures.extend(failures)
            
            for failure in failures:
                failure_analysis["failure_details"].append({
                    "platform": platform_key,
                    "test_name": failure.get("test_name", "unknown"),
                    "error_type": failure.get("error_type", "unknown"),
                    "error_message": failure.get("error_message", ""),
                    "stack_trace": failure.get("stack_trace", "")
                })
        
        # Categorize failures
        failure_analysis["platform_specific_failures"] = platform_failures
        
        # Find common failures across platforms
        failure_counts = {}
        for failure in all_failures:
            key = f"{failure.get('test_name', 'unknown')}:{failure.get('error_type', 'unknown')}"
            failure_counts[key] = failure_counts.get(key, 0) + 1
        
        failure_analysis["common_failures"] = [
            {"failure": k, "count": v} for k, v in failure_counts.items() if v > 1
        ]
        
        return failure_analysis
    
    def generate_json_report(self, output_file: str) -> None:
        """Generate comprehensive JSON report."""
        results = self.collect_results()
        
        with open(output_file, 'w') as f:
            json.dump(results, f, indent=2, sort_keys=True)
        
        print(f"JSON report generated: {output_file}")
    
    def generate_html_report(self, output_file: str) -> None:
        """Generate HTML visualization report."""
        results = self.collect_results()
        
        html_content = self._generate_html_content(results)
        
        with open(output_file, 'w') as f:
            f.write(html_content)
        
        print(f"HTML report generated: {output_file}")
    
    def _generate_html_content(self, results: Dict[str, Any]) -> str:
        """Generate HTML content for the report."""
        summary = results["summary"]
        platform_matrix = results["platform_matrix"]
        performance_metrics = results["performance_metrics"]
        failure_analysis = results["failure_analysis"]
        
        html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ZigCat Test Report - {results['session_id']}</title>
    <style>
        body {{ font-family: Arial, sans-serif; margin: 20px; background-color: #f5f5f5; }}
        .container {{ max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }}
        .header {{ text-align: center; margin-bottom: 30px; }}
        .summary {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin-bottom: 30px; }}
        .metric {{ background: #f8f9fa; padding: 15px; border-radius: 6px; text-align: center; }}
        .metric-value {{ font-size: 2em; font-weight: bold; color: #007bff; }}
        .metric-label {{ color: #666; margin-top: 5px; }}
        .matrix {{ margin-bottom: 30px; }}
        .matrix table {{ width: 100%; border-collapse: collapse; }}
        .matrix th, .matrix td {{ padding: 10px; text-align: left; border: 1px solid #ddd; }}
        .matrix th {{ background-color: #f8f9fa; }}
        .status-pass {{ background-color: #d4edda; color: #155724; }}
        .status-fail {{ background-color: #f8d7da; color: #721c24; }}
        .status-not-run {{ background-color: #fff3cd; color: #856404; }}
        .performance {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; margin-bottom: 30px; }}
        .chart {{ background: #f8f9fa; padding: 15px; border-radius: 6px; }}
        .failures {{ margin-bottom: 30px; }}
        .failure-item {{ background: #f8d7da; padding: 10px; margin: 5px 0; border-radius: 4px; border-left: 4px solid #dc3545; }}
        .timestamp {{ color: #666; font-size: 0.9em; }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>ZigCat Docker Test Report</h1>
            <p class="timestamp">Session: {results['session_id']} | Generated: {results['timestamp']}</p>
        </div>
        
        <div class="summary">
            <div class="metric">
                <div class="metric-value">{summary['total_platforms']}</div>
                <div class="metric-label">Total Platforms</div>
            </div>
            <div class="metric">
                <div class="metric-value">{summary['successful_builds']}</div>
                <div class="metric-label">Successful Builds</div>
            </div>
            <div class="metric">
                <div class="metric-value">{summary['total_tests']}</div>
                <div class="metric-label">Total Tests</div>
            </div>
            <div class="metric">
                <div class="metric-value">{summary['success_rate']:.1f}%</div>
                <div class="metric-label">Success Rate</div>
            </div>
            <div class="metric">
                <div class="metric-value">{summary['total_duration']:.1f}s</div>
                <div class="metric-label">Total Duration</div>
            </div>
        </div>
        
        <div class="matrix">
            <h2>Platform Compatibility Matrix</h2>
            <table>
                <thead>
                    <tr>
                        <th>Platform</th>
                        <th>Build Status</th>
                        <th>Test Status</th>
                        <th>Binary Size</th>
                        <th>Issues</th>
                    </tr>
                </thead>
                <tbody>"""
        
        for platform, data in platform_matrix.items():
            build_class = f"status-{data['build_status']}"
            test_class = f"status-{data['test_status'].replace('_', '-')}"
            binary_size = self._format_bytes(data['binary_size'])
            issues_count = len(data['issues'])
            
            html += f"""
                    <tr>
                        <td>{platform}</td>
                        <td class="{build_class}">{data['build_status'].title()}</td>
                        <td class="{test_class}">{data['test_status'].replace('_', ' ').title()}</td>
                        <td>{binary_size}</td>
                        <td>{issues_count} issues</td>
                    </tr>"""
        
        html += """
                </tbody>
            </table>
        </div>
        
        <div class="performance">
            <div class="chart">
                <h3>Binary Sizes</h3>"""
        
        for platform, size in performance_metrics["binary_sizes"].items():
            html += f"<p>{platform}: {self._format_bytes(size)}</p>"
        
        html += """
            </div>
            <div class="chart">
                <h3>Test Durations</h3>"""
        
        for platform, duration in performance_metrics["test_durations"].items():
            html += f"<p>{platform}: {duration:.2f}s</p>"
        
        html += """
            </div>
        </div>"""
        
        if failure_analysis["total_failures"] > 0:
            html += f"""
        <div class="failures">
            <h2>Failure Analysis ({failure_analysis['total_failures']} total failures)</h2>"""
            
            for failure in failure_analysis["failure_details"][:10]:  # Show first 10 failures
                html += f"""
            <div class="failure-item">
                <strong>{failure['platform']}</strong> - {failure['test_name']}<br>
                <em>{failure['error_type']}</em>: {failure['error_message'][:200]}...
            </div>"""
            
            html += """
        </div>"""
        
        html += """
    </div>
</body>
</html>"""
        
        return html
    
    def _format_bytes(self, bytes_value: int) -> str:
        """Format bytes value in human-readable format."""
        if bytes_value == 0:
            return "0 B"
        
        units = ["B", "KB", "MB", "GB"]
        unit_index = 0
        size = float(bytes_value)
        
        while size >= 1024 and unit_index < len(units) - 1:
            size /= 1024
            unit_index += 1
        
        return f"{size:.1f} {units[unit_index]}"
    
    def generate_junit_xml(self, output_file: str) -> None:
        """Generate JUnit XML format for CI integration."""
        results = self.collect_results()
        test_results = results["test_results"]
        
        # Create root testsuite element
        root = ET.Element("testsuites")
        root.set("name", "zigcat-docker-tests")
        root.set("tests", str(results["summary"]["total_tests"]))
        root.set("failures", str(results["summary"]["failed_tests"]))
        root.set("time", str(results["summary"]["total_duration"]))
        
        for test_result in test_results:
            platform_key = test_result.get("platform_key", "unknown")
            
            # Create testsuite for each platform
            testsuite = ET.SubElement(root, "testsuite")
            testsuite.set("name", f"zigcat-{platform_key}")
            testsuite.set("tests", str(test_result.get("total_tests", 0)))
            testsuite.set("failures", str(test_result.get("failed_tests", 0)))
            testsuite.set("time", str(test_result.get("duration", 0)))
            
            # Add individual test cases
            for test_case in test_result.get("test_cases", []):
                testcase = ET.SubElement(testsuite, "testcase")
                testcase.set("name", test_case.get("name", "unknown"))
                testcase.set("classname", f"zigcat.{platform_key}")
                testcase.set("time", str(test_case.get("duration", 0)))
                
                if test_case.get("status") == "fail":
                    failure = ET.SubElement(testcase, "failure")
                    failure.set("message", test_case.get("error_message", "Test failed"))
                    failure.text = test_case.get("stack_trace", "")
                elif test_case.get("status") == "skip":
                    ET.SubElement(testcase, "skipped")
        
        # Write XML file
        tree = ET.ElementTree(root)
        tree.write(output_file, encoding="utf-8", xml_declaration=True)
        
        print(f"JUnit XML report generated: {output_file}")
    
    def generate_text_summary(self, output_file: str) -> None:
        """Generate human-readable text summary."""
        results = self.collect_results()
        summary = results["summary"]
        platform_matrix = results["platform_matrix"]
        failure_analysis = results["failure_analysis"]
        
        with open(output_file, 'w') as f:
            f.write(f"ZigCat Docker Test Report\n")
            f.write(f"========================\n\n")
            f.write(f"Session ID: {results['session_id']}\n")
            f.write(f"Timestamp: {results['timestamp']}\n\n")
            
            f.write(f"Summary:\n")
            f.write(f"--------\n")
            f.write(f"Total Platforms: {summary['total_platforms']}\n")
            f.write(f"Successful Builds: {summary['successful_builds']}\n")
            f.write(f"Failed Builds: {summary['failed_builds']}\n")
            f.write(f"Total Tests: {summary['total_tests']}\n")
            f.write(f"Passed Tests: {summary['passed_tests']}\n")
            f.write(f"Failed Tests: {summary['failed_tests']}\n")
            f.write(f"Success Rate: {summary['success_rate']:.1f}%\n")
            f.write(f"Total Duration: {summary['total_duration']:.1f}s\n\n")
            
            f.write(f"Platform Matrix:\n")
            f.write(f"----------------\n")
            for platform, data in platform_matrix.items():
                f.write(f"{platform:20} | Build: {data['build_status']:4} | Test: {data['test_status']:8} | Size: {self._format_bytes(data['binary_size']):8} | Issues: {len(data['issues'])}\n")
            
            if failure_analysis["total_failures"] > 0:
                f.write(f"\nFailures ({failure_analysis['total_failures']} total):\n")
                f.write(f"----------\n")
                for failure in failure_analysis["failure_details"][:20]:  # Show first 20 failures
                    f.write(f"[{failure['platform']}] {failure['test_name']}: {failure['error_message']}\n")
        
        print(f"Text summary generated: {output_file}")


def main():
    parser = argparse.ArgumentParser(description="Aggregate ZigCat Docker test results")
    parser.add_argument("--results-dir", default="docker-tests/results", 
                       help="Directory containing test results")
    parser.add_argument("--artifacts-dir", default="docker-tests/artifacts",
                       help="Directory containing build artifacts")
    parser.add_argument("--output-dir", default="docker-tests/reports",
                       help="Output directory for reports")
    parser.add_argument("--formats", nargs="+", 
                       choices=["json", "html", "junit", "text"], 
                       default=["json", "html", "text"],
                       help="Report formats to generate")
    
    args = parser.parse_args()
    
    # Create output directory
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Initialize aggregator
    aggregator = TestResultAggregator(args.results_dir, args.artifacts_dir)
    
    # Generate timestamp for report files
    timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    
    # Generate requested report formats
    if "json" in args.formats:
        aggregator.generate_json_report(output_dir / f"test-report-{timestamp}.json")
    
    if "html" in args.formats:
        aggregator.generate_html_report(output_dir / f"test-report-{timestamp}.html")
    
    if "junit" in args.formats:
        aggregator.generate_junit_xml(output_dir / f"test-results-{timestamp}.xml")
    
    if "text" in args.formats:
        aggregator.generate_text_summary(output_dir / f"test-summary-{timestamp}.txt")
    
    print(f"Report generation completed. Session: {aggregator.session_id}")


if __name__ == "__main__":
    main()
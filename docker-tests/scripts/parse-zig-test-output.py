#!/usr/bin/env python3

"""
ZigCat Test Output Parser
Parses Zig test output and converts it to structured JSON format
Handles both unit test and integration test results
"""

import json
import re
import sys
import argparse
from typing import Dict, List, Any, Optional
from dataclasses import dataclass, asdict
from datetime import datetime
import os

@dataclass
class TestResult:
    """Represents a single test result"""
    name: str
    status: str  # "passed", "failed", "skipped"
    duration: float
    output: str
    error_message: Optional[str] = None
    file_path: Optional[str] = None
    line_number: Optional[int] = None

@dataclass
class TestSuite:
    """Represents a test suite (file) result"""
    name: str
    file_path: str
    status: str
    duration: float
    tests: List[TestResult]
    total_tests: int
    passed_tests: int
    failed_tests: int
    skipped_tests: int

@dataclass
class TestReport:
    """Complete test report"""
    platform: str
    architecture: str
    timestamp: str
    summary: Dict[str, int]
    suites: List[TestSuite]
    total_duration: float

class ZigTestOutputParser:
    """Parser for Zig test output"""
    
    def __init__(self):
        # Regex patterns for parsing Zig test output
        self.test_start_pattern = re.compile(r'Test \[(\d+)/(\d+)\] (.+?)\.\.\.', re.MULTILINE)
        self.test_result_pattern = re.compile(r'Test \[(\d+)/(\d+)\] (.+?)\.\.\. (.+)', re.MULTILINE)
        self.test_summary_pattern = re.compile(r'(\d+) passed; (\d+) skipped; (\d+) failed', re.MULTILINE)
        self.compilation_error_pattern = re.compile(r'(.+?):(\d+):(\d+): error: (.+)', re.MULTILINE)
        self.runtime_error_pattern = re.compile(r'thread \d+ panic: (.+)', re.MULTILINE)
        self.duration_pattern = re.compile(r'All (\d+) tests passed in (.+?)s', re.MULTILINE)
        
    def parse_zig_test_output(self, output: str, suite_name: str, file_path: str) -> TestSuite:
        """Parse Zig test output for a single test suite"""
        tests = []
        total_tests = 0
        passed_tests = 0
        failed_tests = 0
        skipped_tests = 0
        suite_duration = 0.0
        suite_status = "passed"
        
        # Extract individual test results
        test_matches = self.test_result_pattern.findall(output)
        
        for match in test_matches:
            test_index, total_count, test_name, result = match
            total_tests = int(total_count)
            
            # Determine test status
            status = "failed"
            error_message = None
            
            if "OK" in result or "PASS" in result:
                status = "passed"
                passed_tests += 1
            elif "SKIP" in result:
                status = "skipped"
                skipped_tests += 1
            else:
                status = "failed"
                failed_tests += 1
                suite_status = "failed"
                
                # Extract error message
                error_match = self.runtime_error_pattern.search(output)
                if error_match:
                    error_message = error_match.group(1)
            
            # Create test result
            test_result = TestResult(
                name=test_name.strip(),
                status=status,
                duration=0.0,  # Zig doesn't provide per-test timing
                output=result.strip(),
                error_message=error_message
            )
            tests.append(test_result)
        
        # Extract compilation errors if present
        compilation_errors = self.compilation_error_pattern.findall(output)
        for error in compilation_errors:
            file_name, line_num, col_num, error_msg = error
            test_result = TestResult(
                name=f"compilation_error_{len(tests)}",
                status="failed",
                duration=0.0,
                output=f"Compilation error at {file_name}:{line_num}:{col_num}",
                error_message=error_msg,
                file_path=file_name,
                line_number=int(line_num)
            )
            tests.append(test_result)
            failed_tests += 1
            suite_status = "failed"
        
        # Extract total duration if available
        duration_match = self.duration_pattern.search(output)
        if duration_match:
            suite_duration = float(duration_match.group(2))
        
        # If no individual tests found, check for summary
        if not tests:
            summary_match = self.test_summary_pattern.search(output)
            if summary_match:
                passed_tests = int(summary_match.group(1))
                skipped_tests = int(summary_match.group(2))
                failed_tests = int(summary_match.group(3))
                total_tests = passed_tests + skipped_tests + failed_tests
                
                if failed_tests > 0:
                    suite_status = "failed"
        
        return TestSuite(
            name=suite_name,
            file_path=file_path,
            status=suite_status,
            duration=suite_duration,
            tests=tests,
            total_tests=total_tests,
            passed_tests=passed_tests,
            failed_tests=failed_tests,
            skipped_tests=skipped_tests
        )
    
    def parse_integration_test_output(self, output: str, test_name: str) -> TestResult:
        """Parse integration test output"""
        status = "passed"
        error_message = None
        
        # Check for common failure indicators
        if "✗" in output or "FAILED" in output or "ERROR" in output:
            status = "failed"
            # Extract error message from last few lines
            lines = output.strip().split('\n')
            error_lines = [line for line in lines if "✗" in line or "ERROR" in line]
            if error_lines:
                error_message = error_lines[-1]
        elif "⚠" in output or "SKIP" in output:
            status = "skipped"
        
        return TestResult(
            name=test_name,
            status=status,
            duration=0.0,
            output=output,
            error_message=error_message
        )

def parse_test_logs(logs_dir: str, platform: str, architecture: str) -> TestReport:
    """Parse all test logs for a platform/architecture combination"""
    parser = ZigTestOutputParser()
    suites = []
    total_duration = 0.0
    
    # Summary counters
    total_tests = 0
    total_passed = 0
    total_failed = 0
    total_skipped = 0
    
    # Parse Zig unit test logs
    zig_test_files = [
        "cli_test.log",
        "net_test.log",
        "security_test.log",
        "proxy_test.log",
        "tls_test.log",
        "transfer_test.log",
        "integration_test.log",
        "platform_test.log",
        "exec_safety_test.log"
    ]
    
    for test_file in zig_test_files:
        log_path = os.path.join(logs_dir, test_file)
        if os.path.exists(log_path):
            try:
                with open(log_path, 'r') as f:
                    output = f.read()
                
                suite_name = test_file.replace('.log', '')
                suite = parser.parse_zig_test_output(output, suite_name, test_file)
                suites.append(suite)
                
                total_duration += suite.duration
                total_tests += suite.total_tests
                total_passed += suite.passed_tests
                total_failed += suite.failed_tests
                total_skipped += suite.skipped_tests
                
            except Exception as e:
                print(f"Error parsing {log_path}: {e}", file=sys.stderr)
    
    # Parse integration test logs
    integration_test_files = [
        "binary-functionality.log",
        "server-client-basic.log",
        "tcp-echo.log",
        "udp-echo.log"
    ]
    
    integration_tests = []
    for test_file in integration_test_files:
        log_path = os.path.join(logs_dir, test_file)
        if os.path.exists(log_path):
            try:
                with open(log_path, 'r') as f:
                    output = f.read()
                
                test_name = test_file.replace('.log', '')
                test_result = parser.parse_integration_test_output(output, test_name)
                integration_tests.append(test_result)
                
                total_tests += 1
                if test_result.status == "passed":
                    total_passed += 1
                elif test_result.status == "failed":
                    total_failed += 1
                else:
                    total_skipped += 1
                    
            except Exception as e:
                print(f"Error parsing {log_path}: {e}", file=sys.stderr)
    
    # Create integration test suite
    if integration_tests:
        integration_suite = TestSuite(
            name="integration_tests",
            file_path="integration",
            status="passed" if all(t.status != "failed" for t in integration_tests) else "failed",
            duration=0.0,
            tests=integration_tests,
            total_tests=len(integration_tests),
            passed_tests=len([t for t in integration_tests if t.status == "passed"]),
            failed_tests=len([t for t in integration_tests if t.status == "failed"]),
            skipped_tests=len([t for t in integration_tests if t.status == "skipped"])
        )
        suites.append(integration_suite)
    
    # Create test report
    return TestReport(
        platform=platform,
        architecture=architecture,
        timestamp=datetime.now().isoformat(),
        summary={
            "total_tests": total_tests,
            "passed_tests": total_passed,
            "failed_tests": total_failed,
            "skipped_tests": total_skipped
        },
        suites=suites,
        total_duration=total_duration
    )

def generate_junit_xml(report: TestReport, output_file: str):
    """Generate JUnit XML format for CI integration"""
    try:
        from xml.etree.ElementTree import Element, SubElement, tostring
        from xml.dom import minidom
    except ImportError:
        print("Warning: XML generation not available", file=sys.stderr)
        return
    
    # Create root testsuites element
    testsuites = Element('testsuites')
    testsuites.set('name', f'ZigCat-{report.platform}-{report.architecture}')
    testsuites.set('tests', str(report.summary['total_tests']))
    testsuites.set('failures', str(report.summary['failed_tests']))
    testsuites.set('skipped', str(report.summary['skipped_tests']))
    testsuites.set('time', str(report.total_duration))
    testsuites.set('timestamp', report.timestamp)
    
    # Add each test suite
    for suite in report.suites:
        testsuite = SubElement(testsuites, 'testsuite')
        testsuite.set('name', suite.name)
        testsuite.set('tests', str(suite.total_tests))
        testsuite.set('failures', str(suite.failed_tests))
        testsuite.set('skipped', str(suite.skipped_tests))
        testsuite.set('time', str(suite.duration))
        
        # Add each test case
        for test in suite.tests:
            testcase = SubElement(testsuite, 'testcase')
            testcase.set('name', test.name)
            testcase.set('classname', suite.name)
            testcase.set('time', str(test.duration))
            
            if test.status == 'failed':
                failure = SubElement(testcase, 'failure')
                failure.set('message', test.error_message or 'Test failed')
                failure.text = test.output
            elif test.status == 'skipped':
                skipped = SubElement(testcase, 'skipped')
                skipped.set('message', 'Test skipped')
    
    # Write XML file
    rough_string = tostring(testsuites, 'utf-8')
    reparsed = minidom.parseString(rough_string)
    
    with open(output_file, 'w') as f:
        f.write(reparsed.toprettyxml(indent="  "))

def main():
    parser = argparse.ArgumentParser(description='Parse ZigCat test output')
    parser.add_argument('logs_dir', help='Directory containing test logs')
    parser.add_argument('--platform', required=True, help='Test platform')
    parser.add_argument('--architecture', required=True, help='Test architecture')
    parser.add_argument('--output', help='Output JSON file')
    parser.add_argument('--junit', help='Output JUnit XML file')
    parser.add_argument('--verbose', action='store_true', help='Verbose output')
    
    args = parser.parse_args()
    
    if not os.path.exists(args.logs_dir):
        print(f"Error: Logs directory not found: {args.logs_dir}", file=sys.stderr)
        sys.exit(1)
    
    # Parse test logs
    try:
        report = parse_test_logs(args.logs_dir, args.platform, args.architecture)
    except Exception as e:
        print(f"Error parsing test logs: {e}", file=sys.stderr)
        sys.exit(1)
    
    # Output JSON report
    if args.output:
        with open(args.output, 'w') as f:
            json.dump(asdict(report), f, indent=2)
        if args.verbose:
            print(f"JSON report written to: {args.output}")
    else:
        print(json.dumps(asdict(report), indent=2))
    
    # Output JUnit XML if requested
    if args.junit:
        generate_junit_xml(report, args.junit)
        if args.verbose:
            print(f"JUnit XML written to: {args.junit}")
    
    # Print summary
    if args.verbose:
        print(f"\nTest Summary for {args.platform}-{args.architecture}:")
        print(f"  Total tests: {report.summary['total_tests']}")
        print(f"  Passed: {report.summary['passed_tests']}")
        print(f"  Failed: {report.summary['failed_tests']}")
        print(f"  Skipped: {report.summary['skipped_tests']}")
        print(f"  Duration: {report.total_duration:.2f}s")
    
    # Exit with error code if tests failed
    if report.summary['failed_tests'] > 0:
        sys.exit(1)

if __name__ == '__main__':
    main()
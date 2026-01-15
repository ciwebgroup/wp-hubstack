#!/usr/bin/env python3
"""
WordPress Container Performance Analyzer and Auto-Tuner

This tool diagnoses and fixes CPU starvation and resource allocation issues
in dockerized WordPress containers.
"""

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Dict, List, Tuple
import re
import yaml


@dataclass
class ContainerResources:
    """Container resource allocation and usage."""
    cpu_limit: float
    memory_limit: int
    cpu_usage_percent: float
    memory_usage_percent: float
    pids: int
    name: str


@dataclass
class ApacheConfig:
    """Apache MPM configuration."""
    mpm_module: str
    max_request_workers: int
    current_processes: int
    server_limit: Optional[int] = None
    threads_per_child: Optional[int] = None


@dataclass
class PluginProfile:
    """Performance profile for a WordPress plugin."""
    name: str
    cron_jobs: int
    error_mentions: int
    slow_queries: int
    hook_count: int
    estimated_impact: str  # 'low', 'medium', 'high', 'critical'


@dataclass
class DiagnosticResult:
    """Results from container diagnostics."""
    container: ContainerResources
    apache: ApacheConfig
    php_memory_limit: str
    redis_connected: bool
    error_count_recent: int
    request_count_recent: int
    plugins_count: int
    system_load: Tuple[float, float, float]
    plugin_profiles: List[PluginProfile]
    slow_urls: List[Tuple[str, int]]  # (url, count)
    recommendations: List[str]


class DockerClient:
    """Wrapper for Docker CLI operations."""
    
    @staticmethod
    def run_command(cmd: List[str], check: bool = True) -> Tuple[str, int]:
        """Run a shell command and return output and exit code."""
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=check
            )
            return result.stdout.strip(), result.returncode
        except subprocess.CalledProcessError as e:
            return e.stdout.strip() if e.stdout else e.stderr.strip(), e.returncode
    
    @staticmethod
    def exec_in_container(container: str, cmd: str) -> Tuple[str, int]:
        """Execute command inside a Docker container."""
        full_cmd = ["docker", "exec", container, "bash", "-c", cmd]
        return DockerClient.run_command(full_cmd, check=False)
    
    @staticmethod
    def get_container_resources(container: str) -> Optional[ContainerResources]:
        """Get container resource limits and current usage."""
        # Get limits
        inspect_cmd = [
            "docker", "inspect", container,
            "--format", "{{json .HostConfig}}"
        ]
        output, code = DockerClient.run_command(inspect_cmd, check=False)
        if code != 0:
            return None
        
        limits = json.loads(output)
        nano_cpus = limits.get("NanoCpus", 0)
        cpu_limit = nano_cpus / 1_000_000_000 if nano_cpus else 0
        memory_limit = limits.get("Memory", 0)
        
        # Get current usage
        stats_cmd = ["docker", "stats", container, "--no-stream", "--format", "{{json .}}"]
        output, code = DockerClient.run_command(stats_cmd, check=False)
        if code != 0:
            return None
        
        stats = json.loads(output)
        cpu_percent = float(stats.get("CPUPerc", "0").rstrip("%"))
        mem_percent = float(stats.get("MemPerc", "0").rstrip("%"))
        pids = int(stats.get("PIDs", "0"))
        
        return ContainerResources(
            cpu_limit=cpu_limit,
            memory_limit=memory_limit,
            cpu_usage_percent=cpu_percent,
            memory_usage_percent=mem_percent,
            pids=pids,
            name=container
        )


class WordPressAnalyzer:
    """Analyze WordPress container performance issues."""
    
    def __init__(self, container_name: str, site_path: Path):
        self.container_name = container_name
        self.site_path = site_path
        self.docker = DockerClient()
    
    def diagnose(self) -> DiagnosticResult:
        """Run complete diagnostic analysis."""
        print(f"🔍 Analyzing container: {self.container_name}")
        
        resources = self._get_resources()
        apache = self._get_apache_config()
        php_memory = self._get_php_memory_limit()
        redis = self._check_redis()
        errors, requests = self._analyze_logs()
        plugins = self._count_plugins()
        load = self._get_system_load()
        
        print("🔌 Profiling plugins...")
        plugin_profiles = self._profile_plugins()
        slow_urls = self._analyze_slow_urls()
        
        recommendations = self._generate_recommendations(
            resources, apache, php_memory, redis, errors, plugin_profiles
        )
        
        return DiagnosticResult(
            container=resources,
            apache=apache,
            php_memory_limit=php_memory,
            redis_connected=redis,
            error_count_recent=errors,
            request_count_recent=requests,
            plugins_count=plugins,
            system_load=load,
            plugin_profiles=plugin_profiles,
            slow_urls=slow_urls,
            recommendations=recommendations
        )
    
    def _get_resources(self) -> ContainerResources:
        """Get container resource allocation."""
        resources = self.docker.get_container_resources(self.container_name)
        if not resources:
            raise RuntimeError(f"Failed to get resources for {self.container_name}")
        return resources
    
    def _get_apache_config(self) -> ApacheConfig:
        """Get Apache MPM configuration."""
        # Get MPM module
        output, _ = self.docker.exec_in_container(
            self.container_name,
            "apache2ctl -M 2>/dev/null | grep -E 'mpm_' | awk '{print $1}'"
        )
        mpm_module = output.strip().replace("_module", "")
        
        # Get MaxRequestWorkers
        output, _ = self.docker.exec_in_container(
            self.container_name,
            "grep -h MaxRequestWorkers /etc/apache2/mods-available/mpm_*.conf 2>/dev/null | "
            "grep -v '^#' | awk '{print $2}' | head -1"
        )
        max_workers = int(output) if output and output.isdigit() else 150
        
        # Count current Apache processes
        output, _ = self.docker.exec_in_container(
            self.container_name,
            "ps aux | grep apache2 | grep -v grep | wc -l"
        )
        current_procs = int(output) if output and output.isdigit() else 0
        
        return ApacheConfig(
            mpm_module=mpm_module,
            max_request_workers=max_workers,
            current_processes=current_procs
        )
    
    def _get_php_memory_limit(self) -> str:
        """Get PHP memory limit."""
        output, _ = self.docker.exec_in_container(
            self.container_name,
            "php -i | grep 'memory_limit' | head -1 | awk '{print $3}'"
        )
        return output.strip() if output else "Unknown"
    
    def _check_redis(self) -> bool:
        """Check Redis connectivity."""
        output, code = self.docker.exec_in_container(
            self.container_name,
            "wp cache flush --path=/var/www/html --allow-root 2>&1"
        )
        return code == 0 and "Success" in output
    
    def _analyze_logs(self) -> Tuple[int, int]:
        """Analyze recent logs for errors and request count."""
        output, _ = self.docker.run_command(
            ["docker", "logs", self.container_name, "--since", "10m"],
            check=False
        )
        
        error_count = output.count(" 500 ")
        request_count = output.count(" HTTP/")
        
        return error_count, request_count
    
    def _count_plugins(self) -> int:
        """Count active WordPress plugins."""
        output, code = self.docker.exec_in_container(
            self.container_name,
            "wp plugin list --status=active --path=/var/www/html --allow-root --format=count 2>/dev/null"
        )
        return int(output) if code == 0 and output.isdigit() else 0
    
    def _get_system_load(self) -> Tuple[float, float, float]:
        """Get system load average."""
        output, _ = self.docker.run_command(["uptime"], check=False)
        match = re.search(r'load average: ([\d.]+), ([\d.]+), ([\d.]+)', output)
        if match:
            return float(match.group(1)), float(match.group(2)), float(match.group(3))
        return 0.0, 0.0, 0.0
    
    def _profile_plugins(self) -> List[PluginProfile]:
        """Profile each plugin's performance impact."""
        # Get list of active plugins
        output, code = self.docker.exec_in_container(
            self.container_name,
            "wp plugin list --status=active --path=/var/www/html --allow-root "
            "--format=csv --fields=name 2>/dev/null"
        )
        
        if code != 0 or not output:
            return []
        
        plugin_names = [line.strip() for line in output.split('\n')[1:] if line.strip()]
        profiles = []
        
        for plugin_name in plugin_names:
            profile = self._analyze_plugin(plugin_name)
            if profile:
                profiles.append(profile)
        
        # Sort by estimated impact
        impact_order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
        profiles.sort(key=lambda p: impact_order.get(p.estimated_impact, 4))
        
        return profiles
    
    def _analyze_plugin(self, plugin_name: str) -> Optional[PluginProfile]:
        """Analyze a single plugin's performance impact."""
        # Count cron jobs for this plugin
        cron_output, _ = self.docker.exec_in_container(
            self.container_name,
            f"wp cron event list --path=/var/www/html --allow-root --format=csv 2>/dev/null | "
            f"grep -i '{plugin_name}' | wc -l"
        )
        cron_jobs = int(cron_output.strip()) if cron_output.strip().isdigit() else 0
        
        # Check debug log for plugin errors (last 1000 lines)
        error_output, _ = self.docker.exec_in_container(
            self.container_name,
            f"tail -1000 /var/www/html/wp-content/debug.log 2>/dev/null | "
            f"grep -c '/plugins/{plugin_name}/' || echo 0"
        )
        error_mentions = int(error_output.strip()) if error_output.strip().isdigit() else 0
        
        # Check for slow query mentions (if query monitor or similar is active)
        slow_query_output, _ = self.docker.exec_in_container(
            self.container_name,
            f"tail -1000 /var/www/html/wp-content/debug.log 2>/dev/null | "
            f"grep -iE '(slow|timeout|exceeded).*plugins/{plugin_name}' | wc -l"
        )
        slow_queries = int(slow_query_output.strip()) if slow_query_output.strip().isdigit() else 0
        
        # Get hook count (approximate plugin complexity)
        hook_output, _ = self.docker.exec_in_container(
            self.container_name,
            f"grep -r \"add_action\\|add_filter\" "
            f"/var/www/html/wp-content/plugins/{plugin_name}/ 2>/dev/null | wc -l"
        )
        hook_count = int(hook_output.strip()) if hook_output.strip().isdigit() else 0
        
        # Estimate impact based on metrics
        impact = self._estimate_plugin_impact(
            plugin_name, cron_jobs, error_mentions, slow_queries, hook_count
        )
        
        return PluginProfile(
            name=plugin_name,
            cron_jobs=cron_jobs,
            error_mentions=error_mentions,
            slow_queries=slow_queries,
            hook_count=hook_count,
            estimated_impact=impact
        )
    
    def _estimate_plugin_impact(
        self,
        plugin_name: str,
        cron_jobs: int,
        errors: int,
        slow_queries: int,
        hooks: int
    ) -> str:
        """Estimate plugin's performance impact."""
        # Known heavy plugins
        heavy_plugins = {
            'elementor': 'high',
            'elementor-pro': 'high',
            'wp-rocket': 'medium',
            'rank-math': 'high',
            'seo-by-rank-math-pro': 'high',
            'link-whisper': 'high',
            'link-whisper-premium': 'high',
            'wp-smushit': 'medium',
            'smush': 'medium',
            'wordfence': 'high',
            'jetpack': 'high',
            'yoast': 'medium',
            'woocommerce': 'high',
            'gravity-forms': 'medium',
            'gravityforms': 'medium',
            'stream': 'medium',
            'query-monitor': 'low',
        }
        
        # Check if it's a known heavy plugin
        for known_plugin, impact in heavy_plugins.items():
            if known_plugin in plugin_name.lower():
                # Upgrade impact if metrics are bad
                if errors > 50 or slow_queries > 10:
                    return 'critical'
                return impact
        
        # Calculate based on metrics
        score = 0
        
        if errors > 50:
            score += 3
        elif errors > 20:
            score += 2
        elif errors > 5:
            score += 1
        
        if slow_queries > 10:
            score += 3
        elif slow_queries > 5:
            score += 2
        elif slow_queries > 0:
            score += 1
        
        if cron_jobs > 5:
            score += 2
        elif cron_jobs > 2:
            score += 1
        
        if hooks > 200:
            score += 2
        elif hooks > 100:
            score += 1
        
        if score >= 6:
            return 'critical'
        elif score >= 4:
            return 'high'
        elif score >= 2:
            return 'medium'
        else:
            return 'low'
    
    def _analyze_slow_urls(self) -> List[Tuple[str, int]]:
        """Analyze which URLs are generating the most errors or slow responses."""
        output, _ = self.docker.run_command(
            ["docker", "logs", self.container_name, "--since", "30m"],
            check=False
        )
        
        # Extract URLs from 500 errors
        url_pattern = r'"(?:GET|POST) ([^ ]+) HTTP[^"]*" 500'
        urls = re.findall(url_pattern, output)
        
        # Count occurrences
        url_counts: Dict[str, int] = {}
        for url in urls:
            url_counts[url] = url_counts.get(url, 0) + 1
        
        # Sort by count and return top 10
        sorted_urls = sorted(url_counts.items(), key=lambda x: x[1], reverse=True)
        return sorted_urls[:10]
    
    def _generate_recommendations(
        self,
        resources: ContainerResources,
        apache: ApacheConfig,
        php_memory: str,
        redis: bool,
        errors: int,
        plugin_profiles: List[PluginProfile]
    ) -> List[str]:
        """Generate optimization recommendations."""
        recommendations = []
        
        # CPU starvation check
        if resources.cpu_limit > 0:
            workers_per_cpu = apache.max_request_workers / resources.cpu_limit
            if workers_per_cpu > 20:
                recommendations.append(
                    f"⚠️  CRITICAL: {apache.max_request_workers} Apache workers for "
                    f"{resources.cpu_limit} CPUs = {workers_per_cpu:.0f} workers/CPU. "
                    f"Reduce MaxRequestWorkers to {int(resources.cpu_limit * 15)}"
                )
        
        # CPU usage check
        if resources.cpu_usage_percent > 90:
            recommendations.append(
                f"⚠️  High CPU usage ({resources.cpu_usage_percent:.1f}%). "
                "Consider increasing CPU allocation or reducing workers."
            )
        
        # Memory check
        if resources.memory_usage_percent > 85:
            recommendations.append(
                f"⚠️  High memory usage ({resources.memory_usage_percent:.1f}%). "
                "Consider increasing memory allocation."
            )
        
        # Redis check
        if not redis:
            recommendations.append(
                "⚠️  Redis cache not functioning properly. Check connectivity."
            )
        
        # Error rate check
        if errors > 50:
            recommendations.append(
                f"⚠️  High error rate: {errors} HTTP 500 errors in last 10 minutes."
            )
        
        # Apache process check
        if apache.current_processes >= apache.max_request_workers:
            recommendations.append(
                f"⚠️  Apache at capacity: {apache.current_processes}/{apache.max_request_workers} processes."
            )
        
        # MPM suggestion
        if apache.mpm_module == "mpm_prefork" and resources.cpu_limit >= 2:
            recommendations.append(
                "💡 Consider switching to mpm_event for better concurrency with multi-core setup."
            )
        
        # Plugin-specific recommendations
        critical_plugins = [p for p in plugin_profiles if p.estimated_impact == 'critical']
        high_impact_plugins = [p for p in plugin_profiles if p.estimated_impact == 'high']
        
        if critical_plugins:
            plugin_names = ', '.join([p.name for p in critical_plugins])
            recommendations.append(
                f"🔴 CRITICAL: High-impact plugins detected: {plugin_names}. "
                "Consider disabling temporarily or optimizing their configuration."
            )
        
        if high_impact_plugins:
            plugin_names = ', '.join([p.name for p in high_impact_plugins[:3]])
            recommendations.append(
                f"⚠️  Heavy plugins detected: {plugin_names}. Monitor their performance impact."
            )
        
        # Check for plugins with excessive errors
        error_plugins = [p for p in plugin_profiles if p.error_mentions > 20]
        if error_plugins:
            plugin_names = ', '.join([f"{p.name} ({p.error_mentions} errors)" for p in error_plugins])
            recommendations.append(
                f"⚠️  Plugins generating errors: {plugin_names}. Check debug.log for details."
            )
        
        if not recommendations:
            recommendations.append("✅ No critical issues detected. Container is healthy.")
        
        return recommendations


class ConfigPatcher:
    """Apply configuration patches to fix performance issues."""
    
    def __init__(self, site_path: Path, dry_run: bool = False):
        self.site_path = site_path
        self.docker_compose_path = site_path / "docker-compose.yml"
        self.dry_run = dry_run
    
    def apply_cpu_fix(self, current_cpus: float, target_cpus: float) -> bool:
        """Update CPU allocation in docker-compose.yml."""
        if not self.docker_compose_path.exists():
            print(f"❌ docker-compose.yml not found at {self.docker_compose_path}")
            return False
        
        if self.dry_run:
            print(f"🔍 [DRY-RUN] Would update CPU limit: {current_cpus} → {target_cpus}")
            print(f"    File: {self.docker_compose_path}")
            print(f"    Change: deploy.resources.limits.cpus = {target_cpus}")
            return True
        
        with open(self.docker_compose_path, 'r') as f:
            config = yaml.safe_load(f)
        
        service_name = list(config['services'].keys())[0]
        
        if 'deploy' not in config['services'][service_name]:
            config['services'][service_name]['deploy'] = {}
        if 'resources' not in config['services'][service_name]['deploy']:
            config['services'][service_name]['deploy']['resources'] = {}
        if 'limits' not in config['services'][service_name]['deploy']['resources']:
            config['services'][service_name]['deploy']['resources']['limits'] = {}
        
        config['services'][service_name]['deploy']['resources']['limits']['cpus'] = str(target_cpus)
        
        with open(self.docker_compose_path, 'w') as f:
            yaml.dump(config, f, default_flow_style=False, sort_keys=False)
        
        print(f"✅ Updated CPU limit: {current_cpus} → {target_cpus}")
        return True
    
    def apply_memory_fix(self, target_memory_gb: int) -> bool:
        """Update memory allocation in docker-compose.yml."""
        if not self.docker_compose_path.exists():
            return False
        
        if self.dry_run:
            print(f"🔍 [DRY-RUN] Would update memory limit: {target_memory_gb}G")
            print(f"    File: {self.docker_compose_path}")
            print(f"    Change: deploy.resources.limits.memory = {target_memory_gb}G")
            print(f"    Change: environment.MEMORY_LIMIT = {int(target_memory_gb * 0.75 * 1024)}M")
            return True
        
        with open(self.docker_compose_path, 'r') as f:
            config = yaml.safe_load(f)
        
        service_name = list(config['services'].keys())[0]
        
        memory_str = f"{target_memory_gb}G"
        config['services'][service_name]['deploy']['resources']['limits']['memory'] = memory_str
        
        # Update environment variable
        env_list = config['services'][service_name].get('environment', [])
        updated = False
        for i, env in enumerate(env_list):
            if isinstance(env, str) and env.startswith('MEMORY_LIMIT='):
                env_list[i] = f'MEMORY_LIMIT={int(target_memory_gb * 0.75 * 1024)}M'
                updated = True
                break
        
        if not updated:
            env_list.append(f'MEMORY_LIMIT={int(target_memory_gb * 0.75 * 1024)}M')
        
        config['services'][service_name]['environment'] = env_list
        
        with open(self.docker_compose_path, 'w') as f:
            yaml.dump(config, f, default_flow_style=False, sort_keys=False)
        
        print(f"✅ Updated memory limit: {target_memory_gb}G")
        return True
    
    def create_mpm_config(
        self,
        mpm_type: str,
        max_workers: int,
        cpus: float
    ) -> bool:
        """Create optimized Apache MPM configuration."""
        config_path = self.site_path / f"mpm_{mpm_type}.conf"
        
        if self.dry_run:
            print(f"🔍 [DRY-RUN] Would create: {config_path}")
            print(f"    MPM Type: {mpm_type}")
            print(f"    MaxRequestWorkers: {max_workers}")
            print(f"    Optimized for: {cpus} CPUs")
            return True
        
        if mpm_type == "prefork":
            content = f"""# prefork MPM
# Optimized for {cpus} CPU cores

<IfModule mpm_prefork_module>
    StartServers            5
    MinSpareServers         5
    MaxSpareServers         10
    MaxRequestWorkers       {max_workers}
    MaxConnectionsPerChild  1000
</IfModule>
"""
        else:  # event
            threads_per_child = 25
            server_limit = max_workers // threads_per_child + 1
            content = f"""# event MPM
# Optimized for {cpus} CPU cores

<IfModule mpm_event_module>
    ServerLimit             {server_limit}
    StartServers            2
    MinSpareThreads         25
    MaxSpareThreads         75
    ThreadsPerChild         {threads_per_child}
    MaxRequestWorkers       {max_workers}
    MaxConnectionsPerChild  1000
</IfModule>
"""
        
        with open(config_path, 'w') as f:
            f.write(content)
        
        print(f"✅ Created {config_path}")
        return self._add_mpm_volume(mpm_type)
    
    def _add_mpm_volume(self, mpm_type: str) -> bool:
        """Add MPM config to docker-compose volumes."""
        if not self.docker_compose_path.exists():
            return False
        
        with open(self.docker_compose_path, 'r') as f:
            config = yaml.safe_load(f)
        
        service_name = list(config['services'].keys())[0]
        volumes = config['services'][service_name].get('volumes', [])
        
        mpm_volume = f"./mpm_{mpm_type}.conf:/etc/apache2/mods-available/mpm_{mpm_type}.conf:ro"
        
        if mpm_volume not in volumes:
            volumes.append(mpm_volume)
            config['services'][service_name]['volumes'] = volumes
            
            with open(self.docker_compose_path, 'w') as f:
                yaml.dump(config, f, default_flow_style=False, sort_keys=False)
        
        return True
    
    def create_php_ini(self, memory_limit: str) -> bool:
        """Create PHP configuration file."""
        php_ini_path = self.site_path / "php.ini"
        
        if self.dry_run:
            print(f"🔍 [DRY-RUN] Would create: {php_ini_path}")
            print(f"    memory_limit = {memory_limit}")
            print(f"    upload_max_filesize = 128M")
            print(f"    post_max_size = 256M")
            print(f"    max_execution_time = 600")
            return True
        
        content = f"""file_uploads = On
memory_limit = {memory_limit}
upload_max_filesize = 128M
post_max_size = 256M
max_execution_time = 600
"""
        
        with open(php_ini_path, 'w') as f:
            f.write(content)
        
        print(f"✅ Created {php_ini_path}")
        
        # Add to volumes
        return self._add_php_ini_volume()
    
    def _add_php_ini_volume(self) -> bool:
        """Add php.ini to docker-compose volumes."""
        if not self.docker_compose_path.exists():
            return False
        
        with open(self.docker_compose_path, 'r') as f:
            config = yaml.safe_load(f)
        
        service_name = list(config['services'].keys())[0]
        volumes = config['services'][service_name].get('volumes', [])
        
        php_volume = "./php.ini:/usr/local/etc/php/conf.d/custom.ini:ro"
        
        if php_volume not in volumes:
            volumes.append(php_volume)
            config['services'][service_name]['volumes'] = volumes
            
            with open(self.docker_compose_path, 'w') as f:
                yaml.dump(config, f, default_flow_style=False, sort_keys=False)
        
        return True


def print_diagnostic_report(result: DiagnosticResult) -> None:
    """Print formatted diagnostic report."""
    print("\n" + "=" * 80)
    print("📊 WORDPRESS CONTAINER DIAGNOSTIC REPORT")
    print("=" * 80)
    
    print(f"\n🐳 Container: {result.container.name}")
    print(f"   CPU Limit: {result.container.cpu_limit} cores")
    print(f"   CPU Usage: {result.container.cpu_usage_percent:.2f}%")
    print(f"   Memory Limit: {result.container.memory_limit / (1024**3):.1f}G")
    print(f"   Memory Usage: {result.container.memory_usage_percent:.2f}%")
    if result.plugin_profiles:
        print(f"\n📊 Plugin Performance Profile:")
        # Show critical and high impact plugins
        critical_high = [p for p in result.plugin_profiles 
                        if p.estimated_impact in ['critical', 'high']]
        
        if critical_high:
            print("   High Impact Plugins:")
            for plugin in critical_high[:10]:  # Top 10
                impact_icon = "🔴" if plugin.estimated_impact == "critical" else "🟡"
                print(f"   {impact_icon} {plugin.name:<30} "
                      f"Cron: {plugin.cron_jobs:>2} | "
                      f"Errors: {plugin.error_mentions:>3} | "
                      f"Slow: {plugin.slow_queries:>2} | "
                      f"Hooks: {plugin.hook_count:>4}")
        else:
            print("   ✅ No high-impact plugins detected")
    
    if result.slow_urls:
        print(f"\n🐌 Slowest/Error URLs (last 30 min):")
        for url, count in result.slow_urls[:5]:
            print(f"   {count:>3}x  {url}")
    
    print(f"   PIDs: {result.container.pids}")
    
    print(f"\n🌐 Apache Configuration:")
    print(f"   MPM Module: {result.apache.mpm_module}")
    print(f"   MaxRequestWorkers: {result.apache.max_request_workers}")
    print(f"   Current Processes: {result.apache.current_processes}")
    print(f"   Utilization: {result.apache.current_processes}/{result.apache.max_request_workers} "
          f"({result.apache.current_processes/result.apache.max_request_workers*100:.1f}%)")
    
    print(f"\n🐘 PHP Configuration:")
    print(f"   Memory Limit: {result.php_memory_limit}")
    
    print(f"\n💾 Cache & Storage:")
    print(f"   Redis: {'✅ Connected' if result.redis_connected else '❌ Disconnected'}")
    
    print(f"\n📈 Traffic & Errors (last 10 min):")
    print(f"   HTTP Requests: {result.request_count_recent}")
    print(f"   HTTP 500 Errors: {result.error_count_recent}")
    if result.request_count_recent > 0:
        error_rate = (result.error_count_recent / result.request_count_recent) * 100
        print(f"   Error Rate: {error_rate:.2f}%")
    
    print(f"\n🔌 WordPress:")
    print(f"   Active Plugins: {result.plugins_count}")
    
    print(f"\n💻 System Load:")
    print(f"   1m: {result.system_load[0]:.2f}, 5m: {result.system_load[1]:.2f}, "
          f"15m: {result.system_load[2]:.2f}")
    
    print(f"\n🔍 Recommendations:")
    for rec in result.recommendations:
        print(f"   {rec}")
    
    print("\n" + "=" * 80)


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="WordPress Container Performance Analyzer and Auto-Tuner"
    )
    parser.add_argument(
        "container",
        help="Container name (e.g., wp_malibuheatingandair)"
    )
    parser.add_argument(
        "--site-path",
        type=Path,
        help="Path to site directory with docker-compose.yml",
        required=True
    )
    parser.add_argument(
        "--auto-fix",
        action="store_true",
        help="Automatically apply recommended fixes"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what changes would be made without applying them (implies --auto-fix)"
    )
    parser.add_argument(
        "--target-cpus",
        type=float,
        help="Target CPU allocation (if different from recommended)"
    )
    parser.add_argument(
        "--target-memory-gb",
        type=int,
        help="Target memory allocation in GB"
    )
    parser.add_argument(
        "--mpm-event",
        action="store_true",
        help="Generate Apache mpm_event config instead of mpm_prefork"
    )
    
    args = parser.parse_args()
    
    # Validate site path
    if not args.site_path.exists():
        print(f"❌ Site path does not exist: {args.site_path}")
        return 1
    
    # Run diagnostics
    analyzer = WordPressAnalyzer(args.container, args.site_path)
    try:
        result = analyzer.diagnose()
    except Exception as e:
        print(f"❌ Diagnostic failed: {e}")
        return 1
    
    # Print report
    print_diagnostic_report(result)
    
    # Auto-fix or dry-run if requested
    if args.auto_fix or args.dry_run:
        if args.dry_run:
            print("\n🔍 DRY-RUN MODE: Showing what changes would be made...")
        else:
            print("\n🔧 Applying automatic fixes...")
        
        patcher = ConfigPatcher(args.site_path, dry_run=args.dry_run)
        
        # Calculate optimal settings
        current_cpus = result.container.cpu_limit
        target_cpus = args.target_cpus if args.target_cpus else max(2.0, current_cpus * 2)
        target_workers = int(target_cpus * 15)
        
        target_memory_gb = args.target_memory_gb if args.target_memory_gb else 2
        
        # Apply fixes
        if current_cpus < 2 or result.apache.max_request_workers > 50:
            patcher.apply_cpu_fix(current_cpus, target_cpus)
            patcher.apply_memory_fix(target_memory_gb)
            mpm_type = "event" if args.mpm_event else "prefork"
            patcher.create_mpm_config(mpm_type, target_workers, target_cpus)
            patcher.create_php_ini(f"{int(target_memory_gb * 0.5 * 1024)}M")
            
            if args.dry_run:
                print("\n🔍 [DRY-RUN] No files were modified.")
                print("    To apply these changes, run without --dry-run flag.")
            else:
                print("\n✅ Fixes applied! Restart container with:")
                print(f"   cd {args.site_path} && docker-compose down && docker-compose up -d")
        else:
            print("\n✅ No critical fixes needed.")
    
    return 0


if __name__ == "__main__":
    sys.exit(main())

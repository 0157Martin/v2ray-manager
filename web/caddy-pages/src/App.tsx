import { useEffect, useState } from 'react'
import { choose, loadConfig, type PageConfig } from './config'
import './style.css'

const names = ['林知远', '周予安', '陈若川', '许清和', '沈言川']
const roles = ['独立开发者', '产品设计师', '软件工程师', '数字创作者', '研究助理']
const cities = ['杭州', '成都', '厦门', '南京', '深圳']
const work = ['阅读清单', '城市散步', '设计笔记', '开源工具', '个人知识库', '界面练习']
const skills = ['TypeScript', 'UI Systems', 'Writing', 'Prototyping', 'Research', 'Open Source']

function Portfolio({ config }: { config: PageConfig }) {
  const name = choose(names, config.seed, 'name'), role = choose(roles, config.seed, 'role'), city = choose(cities, config.seed, 'city')
  const selected = [0, 1, 2].map((index) => choose(work, config.seed, `work-${index}`))
  return <main className="portfolio"><nav><span className="mark">{name.slice(0, 1)}</span><span>{name}</span><small>{config.domain}</small></nav><header><p className="eyebrow">{city} · PERSONAL NOTES</p><h1>把想法做成<br/><em>可以使用的东西。</em></h1><p className="lead">我是{name}，一名{role}。这里记录正在完成的小项目、阅读与日常观察。</p></header><section><div className="section-label">SELECTED NOTES</div><div className="cards">{selected.map((title, index) => <article key={title}><span>0{index + 1}</span><h2>{title}</h2><p>{['持续整理的信息、工具和方法。', '留给好奇心与慢慢打磨的时间。', '收集片段，等待它们自然连接。'][index]}</p></article>)}</div></section><footer><span>© {new Date().getFullYear()} {name}</span><span>Independent work & notes</span></footer></main>
}

function Resume({ config }: { config: PageConfig }) {
  const name = choose(names, config.seed, 'name'), role = choose(roles, config.seed, 'role'), city = choose(cities, config.seed, 'city')
  return <main className="resume"><aside><div className="avatar">{name.slice(0, 1)}</div><h1>{name}</h1><p>{role}</p><hr/><dl><dt>所在地</dt><dd>{city}</dd><dt>个人网站</dt><dd>{config.domain}</dd><dt>状态</dt><dd>开放交流</dd></dl></aside><article><header><p className="eyebrow">PROFILE / {new Date().getFullYear()}</p><h2>一个专注于细节与长期价值的{role}</h2><p>关注数字产品、工具体验与清晰的信息表达。这个页面用于展示工作方法、项目记录和学习轨迹。</p></header><section><h3>经历</h3><div className="timeline"><div><b>持续实践</b><span>近期</span><p>探索产品、设计与技术之间更自然的协作方式。</p></div><div><b>独立项目</b><span>过去几年</span><p>完成面向真实使用场景的小工具和内容项目。</p></div></div></section><section><h3>能力</h3><div className="skills">{skills.map((skill) => <span key={skill}>{skill}</span>)}</div></section><footer>© {new Date().getFullYear()} {name} · {config.domain}</footer></article></main>
}

export default function App() {
  const [config, setConfig] = useState<PageConfig | null>(null)
  useEffect(() => { loadConfig().then(setConfig) }, [])
  if (!config) return <div className="loading">Loading</div>
  return config.template === 'resume' ? <Resume config={config} /> : <Portfolio config={config} />
}
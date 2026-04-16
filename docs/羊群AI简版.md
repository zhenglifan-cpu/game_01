基于Boids集群行为的羊群AI和玩家驱赶系统（简版）

# 一、算法目标

基于Boids 集群行为和现实牧羊中羊的flocking /following instinct/flight response，实现一套有涌现行为、可调参、适合 Lua 的羊群系统。

这套系统要实现5个结果：

1.自然成群:羊默认倾向于跟随同伴、维持群体，不会长期单独游荡。现实资料也指出羊最典型的行为特征就是强烈的 flocking 与 following instinct。

2.受惊逃逸:羊看到牧羊犬、威胁源或被快速逼近时，会朝远离威胁的方向移动；这对应现实牧羊中的 flight response。

3.局部带动整体:一只羊先跑，邻近羊会通过对齐与聚合加入流动，形成“头羊跑、其他羊跟”的传播效应。

4.慢压可移、猛冲可散:牧羊犬缓慢逼近时，羊群整体位移；快速冲入或吠叫过强时，羊群会短时分裂、散开、惊慌。

5.低规则，高涌现:系统尽量不用复杂状态脚本，而用四条核心规则叠加出群体行为。

# 二、羊群集群AI

## （一）规则说明

Boids 四规则：分离 + 对齐 + 聚合 + 逃逸 - 羊有"视野半径"，只受附近邻居影响- 不同性格的羊（胆小/倔强/领头羊）增加策略深度 - 群体越大越难分散，落单的羊更容易控制

羊不是单独个体，而是一个有涌现行为的集群系统，基于经典 [Boids 算法](https://www.red3d.com/cwr/boids/"%20\t%20"https://maker.taptap.cn/app/_blank)的三条规则：

| 规则  | 行为  | 游戏表现 |
| --- | --- | --- |
| 分离（Separation） | 避免拥挤 | 羊之间保持间距，不会叠在一起 |
| 对齐（Alignment） | 跟随邻居方向 | 一只羊跑动会带动附近的羊跟着跑 |
| 聚合（Cohesion） | 靠近群体中心 | 散开的羊会自动向群体靠拢 |
| 逃逸（Escape） | 逃离牧羊犬 | 检测到牧羊犬/威胁时，朝远离方向逃跑 |

这四条规则的叠加产生了非常自然的羊群行为：冲过去它们会散，慢慢靠近它们会移，头羊跑了其他羊跟着跑。

### 1.分离Separation

**目的：**避免个体重叠，保持自然间距。

**输入：**感知半径内其他羊的位置。

**行为：**对过近邻居产生反向排斥力。

**表现：**

- 羊群不会堆成一个点
- 狭窄处会出现挤压感
- 冲刺进入羊群时，个体会向外散

**核心逻辑：**

- 距离越近，排斥越强
- 只在“过近阈值”内显著生效

**公式概念：**

Separation = Σ normalize(self.pos - neighbor.pos) / distance

### 2.对齐 Alignment

**目的：**让个体跟随邻居方向，形成群体流动。

**输入：**邻居羊的速度向量。

**行为：**向邻居平均速度方向修正自己的速度。

**表现：**

- 一只羊开始跑，周围羊会逐步跟着跑
- 狭道中会形成整体“流”
- 局部方向会传播

**核心逻辑：**

- 附近羊越多，对齐越明显
- 没有邻居时，对齐不生效

**公式概念：**

Alignment = average(neighbor.velocity) - self.velocity

### 3.聚合 Cohesion

**目的：**让羊回到群体中，减少长期脱队。

**输入：**邻居羊的位置中心。

**行为：**朝邻居平均位置靠近。

**表现：**

- 散开的羊会慢慢回群
- 羊群被狗冲散后，会重新聚拢
- 小群会合并成更稳定的大群

**核心逻辑：**

- 距离群体中心越远，聚合越明显
- 在高惊慌时适当降低权重，避免“立刻贴回去”显得僵硬

**公式概念：**

Cohesion = average(neighbor.position) - self.position

### 4.逃逸 Escape

**目的：**模拟羊对牧羊犬、狼、噪声等威胁的逃离反应。

**输入：**

- 牧羊犬位置
- 犬的速度方向
- 吠叫事件
- 其他威胁源

**行为：**

- 朝远离威胁的方向移动
- 威胁越近、越快、越正面，逃逸越强

**表现：**

- 狗慢慢靠近，羊群整体前移
- 狗突然冲进来，羊群局部炸散
- 叫声会造成瞬时转向或加速

现实资料指出，犬只和处理者会被羊视为显著威胁；若处理压力过大，会出现 running、bunching、jumping、squeezing through barriers 等逃逸和挤压行为。这个游戏系统可以用 Escape 权重和 Separation/Cohesion 的再分配来近似。

**公式概念：**

Escape = Σ normalize(self.pos - threat.pos) \* threatInfluence

## （二）羊的状态模型

### 1.Idle 怠速

**触发**

- 附近没有羊
- 附近没有狗
- 没有明显目标

**表现**

- 慢速游走或停顿
- 朝随机微方向摆动

### 2.Flock 跟群

**触发**

- 感知到一定数量邻居
- 没有牧羊犬威胁

**表现**

- Alignment + Cohesion 主导
- 形成稳定羊群流动

### 3.Alert 警觉

**触发**

- 狗进入外圈威胁半径
- 或听到较弱吠叫

**表现**

- 群体方向开始偏转
- 速度轻微增加

### 4.Panic 惊慌

**触发**

- 狗快速冲近
- 吠叫命中
- 多个威胁叠加
- 陷入狭窄且受压

**表现**

- Escape 显著提高
- Separation 提高
- Cohesion 降低
- 速度上升，但方向波动更大

### 5.Recover 恢复

**触发**

- 威胁离开
- 一段时间未再受压

**表现**

- Panic 缓慢衰减
- 羊从炸散回到 flock 状态

## （三）感知系统

每只羊每次更新需要感知：

- 附近羊
- 附近牧羊犬
- 吠叫事件
- 墙体 / 障碍
- 目标点或安全区（可选）

# 三、学习文章

https://blog.csdn.net/qq_42555291/article/details/156271536?spm=1001.2101.3001.6650.16&utm_medium=distribute.pc_relevant.none-task-blog-2%7Edefault%7EBlogCommendFromBaidu%7ERate-16-156271536-blog-120702044.235%5Ev43%5Econtrol&depth_1-utm_source=distribute.pc_relevant.none-task-blog-2%7Edefault%7EBlogCommendFromBaidu%7ERate-16-156271536-blog-120702044.235%5Ev43%5Econtrol&utm_relevant_index=20

https://blog.csdn.net/XiaoChe21/article/details/120702044?spm=1001.2101.3001.6650.3&utm_medium=distribute.pc_relevant.none-task-blog-2%7Edefault%7EBlogCommendFromBaidu%7ERate-3-120702044-blog-158175675.235%5Ev43%5Econtrol&depth_1-utm_source=distribute.pc_relevant.none-task-blog-2%7Edefault%7EBlogCommendFromBaidu%7ERate-3-120702044-blog-158175675.235%5Ev43%5Econtrol&utm_relevant_index=5

https://www.red3d.com/cwr/boids/